module Plume.TypeChecker.Checker.Switch where

import Data.Map qualified as Map
import Plume.Syntax.Abstract qualified as Pre
import Plume.Syntax.Common.Literal
import Plume.Syntax.Common.Pattern qualified as Pre
import Plume.TypeChecker.Checker.Monad
import Plume.TypeChecker.TLIR qualified as Post
import Plume.TypeChecker.Constraints.Solver (unifiesWith)

synthSwitch :: Infer -> Infer
synthSwitch infer (Pre.ESwitch scrutinee cases) = local id $ do
  -- Infer the scrutinee and the cases
  (t, scrutinee') <- extractFromArray $ infer scrutinee
  (tys, cases') <- mapAndUnzipM (synthCase infer t) cases
  let (ts', expr) = unzip tys
  
  (ret, xs) <- case ts' of
    [] -> throw EmptyMatch
    (ret : xs) -> return (ret, xs)
  
  (exprTy, xs') <- case expr of
    [] -> return (ret, [])
    (x : xs'') -> return (x, xs'')

  -- Unify the return type with the type of the case expressions
  forM_ xs $ unifiesWith ret

  -- Unify the scrutinee type with the type of the patterns
  forM_ xs' $ unifiesWith exprTy

  pure (exprTy, [Post.ESwitch scrutinee' cases'])
synthSwitch _ _ = throw $ CompilerError "Only switches are supported"

synthCase
  :: Infer
  -> PlumeType
  -> (Pre.Pattern, Pre.Expression)
  -> Checker ((PlumeType, PlumeType), (Post.Pattern, Post.Expression))
synthCase infer scrutTy (pat, expr) = local id $ do
  -- Synthesize the pattern and infer the expression
  (patTy, patExpr, patEnv) <- synthPattern pat
  (exprTy, expr') <- local id . extractFromArray $ localEnv patEnv (infer expr)

  -- Pattern type should unify with the scrutinee type
  scrutTy `unifiesWith` patTy
  pure ((patTy, exprTy), (patExpr, expr'))

-- | Locally perform an action without changing the environment globally
localEnv :: Map Text PlumeScheme -> Checker a -> Checker a
localEnv env action = do
  vars <- gets (typeEnv . environment)
  insertEnvWith @"typeEnv" (<>) env
  res <- action
  replaceEnv @"typeEnv" vars
  pure res

-- | Synthesizing a pattern consists of inferring the type of the pattern
-- | like regular expressions, but also returning the environment created 
-- | by the pattern (e.g. variables in the pattern).
synthPattern
  :: Pre.Pattern
  -> Checker (PlumeType, Post.Pattern, Map Text PlumeScheme)
synthPattern Pre.PWildcard = do
  t <- fresh
  pure (t, Post.PWildcard, mempty)
synthPattern (Pre.PVariable name) = do
  t <- searchEnv @"datatypeEnv" name
  case t of
    Just t' -> do
      inst <- instantiate t'
      return (inst, Post.PSpecialVar name inst, mempty)
    Nothing -> do
      ty <- fresh
      return
        ( ty
        , Post.PVariable name ty
        , Map.singleton name ty
        )
synthPattern (Pre.PLiteral l) = do
  let (ty, l') = typeOfLiteral l
  pure (ty, Post.PLiteral l', mempty)
synthPattern (Pre.PConstructor name pats) = do
  t <- searchEnv @"datatypeEnv" name
  case t of
    Just t' -> do
      inst <- instantiate t'
      ret <- fresh
      (patsTy, pats', env) <- mapAndUnzip3M synthPattern pats
      inst `unifiesWith` (patsTy :->: ret)
      return (ret, Post.PConstructor name pats', mconcat env)
    Nothing -> throw $ UnboundVariable name
synthPattern (Pre.PList pats slice) = do
  tv <- fresh
  (patsTy, pats', env) <- mapAndUnzip3M synthPattern pats
  forM_ patsTy (`unifiesWith` tv)

  slRes <- maybeM slice synthPattern

  case slRes of
    Just (slTy, sl', slEnv) -> do
      slTy `unifiesWith` TList tv
      return (TList tv, Post.PList pats' (Just sl'), mconcat env <> slEnv)
    Nothing -> return (TList tv, Post.PList pats' Nothing, mconcat env)
synthPattern (Pre.PSlice n) = do
  tv <- fresh
  return
    ( TList tv
    , Post.PVariable n (TList tv)
    , Map.singleton n (TList tv)
    )

typeOfLiteral :: Literal -> (PlumeType, Literal)
typeOfLiteral (LInt i) = (TInt, LInt i)
typeOfLiteral (LFloat f) = (TFloat, LFloat f)
typeOfLiteral (LBool b) = (TBool, LBool b)
typeOfLiteral (LString s) = (TString, LString s)
typeOfLiteral (LChar c) = (TChar, LChar c)

-- | Function that maps monadic actions over a list and then unzips the result
-- | into three separate lists.
mapAndUnzip3M :: (Monad m) => (a -> m (b, c, d)) -> [a] -> m ([b], [c], [d])
mapAndUnzip3M f xs = do
  (bs, cs, ds) <- unzip3 <$> mapM f xs
  pure (bs, cs, ds)