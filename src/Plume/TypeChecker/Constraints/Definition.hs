module Plume.TypeChecker.Constraints.Definition where

import Plume.Syntax.Concrete (Position)
import Plume.TypeChecker.Monad.Type

-- | Type constraints
-- | Used to modelize some equality and equivalence judgements between
-- | types.
-- |
-- | t1 :~: t2 <=> t1 is equivalent to t2 (meaning we could deduce t1 from t2
-- |               and vice-versa)
-- | Hole t <=> `t` is a hole that needs to be filled, used to help the user
-- |            to fill the blanks in the type inference process
data TypeConstraint
  = PlumeType :~: PlumeType
  | Hole PlumeType
  deriving (Eq, Show)

-- | Plume constraint are always bound to a position for better error handling
type PlumeConstraint = (Position, TypeConstraint)
