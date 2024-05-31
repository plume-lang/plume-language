{-# LANGUAGE LambdaCase #-}

module Plume.TypeChecker.Checker where

import Data.List qualified as List
import Plume.Syntax.Abstract qualified as Pre
import Plume.Syntax.Translation.Generics (concatMapM)
import Plume.TypeChecker.Checker.Application
import Plume.TypeChecker.Checker.Closure
import Plume.TypeChecker.Checker.Condition
import Plume.TypeChecker.Checker.Datatype
import Plume.TypeChecker.Checker.Declaration
import Plume.TypeChecker.Checker.Extension
import Plume.TypeChecker.Checker.Interface (synthInterface)
import Plume.TypeChecker.Checker.Native
import Plume.TypeChecker.Checker.Switch
import Plume.TypeChecker.Constraints.Solver
import Plume.TypeChecker.Constraints.Unification
import Plume.TypeChecker.Constraints.Typeclass
import Plume.TypeChecker.Monad
import Plume.TypeChecker.Monad.Conversion
import Plume.TypeChecker.TLIR qualified as Post
import Prelude hiding (gets, local, modify)

synthesize :: (MonadChecker m) => Pre.Expression -> m (PlumeType, [PlumeQualifier], Placeholder Post.Expression)

-- | Some basic and primitive expressions
synthesize (Pre.ELocated expr pos) = withPosition pos $ synthesize expr

{-  
 -  x : (β ⇒ σ) ∈ Γ
 -  ---------------
 -  Γ ⊦ x : (β ⇒ σ)
 -}
synthesize (Pre.EVariable name) = do
  -- Checking if the variable is a value
  searchEnv @"typeEnv" name >>= \case
    Just scheme -> instantiateFromName name scheme
    Nothing ->
      -- Checking if the variable is a data-type constructor
      searchEnv @"datatypeEnv" name >>= \case
        Just sch -> do
          (ty, qs) <- instantiate sch
          pure (ty, qs, pure (Post.EVariable name ty))
        Nothing -> throw (UnboundVariable name)
synthesize (Pre.ELiteral lit) = do
  let (ty, lit') = typeOfLiteral lit
  pure (ty, [], pure (Post.ELiteral lit'))
synthesize (Pre.EUnMut e) = do
  tv <- fresh
  (ty, ps, r) <- synthesize e
  ty `unifiesWith` TMut tv
  pure (tv, ps, Post.EUnMut <$> r)
synthesize (Pre.EBlock exprs) = local id $ do
  (tys, pss, exprs') <-
    mapAndUnzip3M
      (localPosition . synthesize)
      exprs

  retTy <- gets returnType
  let retTy' = fromMaybe TUnit retTy

  return (retTy', concat pss, liftBlock (Post.EBlock <$> sequence exprs') tys retTy')
synthesize (Pre.EReturn expr) = do
  (ty, ps, expr') <- synthesize expr
  returnTy <- gets returnType
  forM_ returnTy $ unifiesWith ty
  pure (ty, ps, Post.EReturn <$> expr')
synthesize (Pre.EList xs) = do
  tv <- fresh
  (tys, pss, xs') <-
    mapAndUnzip3M
      (local id . localPosition . synthesize)
      xs
  forM_ tys $ unifiesWith tv
  pure (TList tv, concat pss, Post.EList <$> sequence xs')
synthesize (Pre.EVariableDeclare gens name ty) = do
  gens' <- concatMapM convert gens
  let qvars = getQVars gens'
  let quals = removeQVars gens'
  ty' <- convert ty

  insertEnv @"typeEnv" name (Forall qvars (quals :=>: ty'))

  let arity = case ty' of
        TFunction args _ -> length args
        _ -> (-1)

  pure (ty', [], pure (Post.EVariableDeclare name arity))
synthesize (Pre.EAwait e) = do
  (ty, ps, e') <- synthesize e

  tv <- fresh
  ty `unifiesWith` TypeApp (TypeId "async") [tv]

  modify (\s -> s {isAsynchronous = True})

  let awaitSig = [ty] :->: tv
  let call ex = Post.EApplication (Post.EVariable "wait" awaitSig) [ex]

  pure (tv, ps, call <$> e')
-- \| Calling synthesis modules
synthesize app@(Pre.EApplication {}) = synthApp synthesize app
synthesize clos@(Pre.EClosure {}) = synthClosure synthesize clos
synthesize decl@(Pre.EDeclaration {}) = synthDecl False synthesize decl
synthesize cond@(Pre.EConditionBranch {}) = synthCond synthesize cond
synthesize ext@(Pre.ETypeExtension {}) = synthExt synthesize ext
synthesize ty@(Pre.EType {}) = synthDataType ty
synthesize sw@(Pre.ESwitch {}) = synthSwitch synthesize sw
synthesize int@(Pre.EInterface {}) = synthInterface synthesize int
synthesize nat@(Pre.ENativeFunction {}) = synthNative nat

synthesizeToplevel :: (MonadChecker m) => Pre.Expression -> m (PlumeScheme, [Post.Expression])
synthesizeToplevel (Pre.ELocated e pos) = withPosition pos $ synthesizeToplevel e
synthesizeToplevel e@(Pre.EDeclaration {}) = do
  (ty, ps, h) <- synthDecl True synthesize e
  cenv <- gets (extendEnv . environment)
  zs <- traverse (discharge cenv) ps

  let (ps', m, as, _) = mconcat zs
  (_, as') <- removeDuplicatesAssumps as
  ps'' <- removeDuplicatesQuals ps'
  let t'' = Forall [] $ List.nub ps'' :=>: ty

  pos <- fetchPosition
  h' <- liftIO $ runReaderT h $ getExpr pos m

  unless (null as') $ do
    throw (UnresolvedTypeVariable as')

  case h' of
    Post.ESpreadable es -> pure (t'', es)
    _ -> pure (t'', [h'])
synthesizeToplevel e = do
  (ty, ps, h) <- synthesize e
  cenv <- gets (extendEnv . environment)
  zs <- traverse (discharge cenv) ps

  let (ps', m, as, _) = mconcat zs
  (_, as') <- removeDuplicatesAssumps as
  ps'' <- removeDuplicatesQuals ps'
  let t'' = Forall [] $ List.nub ps'' :=>: ty

  pos <- fetchPosition
  h' <- liftIO $ runReaderT h $ getExpr pos m

  unless (null as') $ do
    throw (UnresolvedTypeVariable as')

  case h' of
    Post.ESpreadable es -> pure (t'', es)
    _ -> pure (t'', [h'])

-- | Locally synthesize a list of expressions
synthesizeMany :: (MonadChecker m) => [Pre.Expression] -> m [Post.Expression]
synthesizeMany = concatMapM (fmap snd . localPosition . synthesizeToplevel)

runSynthesize :: (MonadIO m) => [Pre.Expression] -> m (Either PlumeError [Post.Expression])
runSynthesize = runExceptT . synthesizeMany
