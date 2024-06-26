module Plume.Syntax.Parser.Modules.Slice where

import Control.Monad.Parser qualified as P
import Text.Megaparsec qualified as P

import Plume.Syntax.Common qualified as Cmm
import Plume.Syntax.Concrete qualified as CST
import Plume.Syntax.Parser.Lexer qualified as L

-- | Parse a slice expression
-- | A slice expression is an expression that is used to slice a list
-- | The slice expression can be used to get a subsequence of a list
-- | or to replace a subsequence of a list
-- | 
-- | example: list[1..5] <=> list.slice(1, 5)
-- |          list [1..] <=> list.slice(1, list.len())
-- |          list [..5] <=> list.slice(0, 5)
parseSlice :: P.Parser CST.Expression -> P.Parser CST.Expression
parseSlice eTerm = do
  res <-
    optional . P.try $
      (,)
        <$> optional eTerm
        <*> (L.symbol ".." *> optional eTerm)
  case res of
    Just (Nothing, Nothing) -> fail "Invalid slice"
    Just (Just e1, Nothing) -> return (CST.EPostfix "slice" e1)
    Just (Nothing, Just e2) -> return (CST.EPrefix "slice" e2)
    Just (Just e1, Just e2) -> return (CST.EBinary "slice" e1 e2)
    Nothing -> eTerm

-- | Transform a slice expression to a slice method call
-- | A slice expression is transformed to a slice method call
-- | in order to simplify the AST
-- |
-- | example: list[1..5] <=> list.slice(1, 5)
-- |          list[1..] <=> list.slice(1, list.len())
-- |          list[..5] <=> list.slice(0, 5)
transformSlice :: CST.Expression -> CST.Expression -> CST.Expression
transformSlice (CST.ELocated e p) e1 = CST.ELocated (transformSlice e e1) p
transformSlice (CST.EBinary "slice" e1 e2) e3 =
  CST.EApplication (CST.EProperty "slice" e3) [e1, e2]
transformSlice (CST.EPostfix "slice" e1) e2 =
  CST.EApplication (CST.EProperty "slice" e2) [e1, len]
 where
  len = CST.EApplication (CST.EProperty "len" e2) []
transformSlice (CST.EPrefix "slice" e2) e1 =
  CST.EApplication (CST.EProperty "slice" e1) [CST.ELiteral (Cmm.LInt 0), e2]
transformSlice e1 e2 = CST.EListIndex e2 e1