{-# LANGUAGE TypeOperators, GADTs, PatternGuards #-}
{-# OPTIONS_GHC -Wall #-}

-- {-# OPTIONS_GHC -fno-warn-unused-imports #-} -- TEMP
-- {-# OPTIONS_GHC -fno-warn-unused-binds   #-} -- TEMP

----------------------------------------------------------------------
-- |
-- Module      :  LambdaCCC.ToCCC
-- Copyright   :  (c) 2013 Tabula, Inc.
-- License     :  BSD3
-- 
-- Maintainer  :  conal@tabula.com
-- Stability   :  experimental
-- 
-- Convert lambda expressions to CCC combinators
----------------------------------------------------------------------

module LambdaCCC.ToCCC (toCCC, toCCC') where

import Data.Functor ((<$>))
import Control.Monad (mplus)
import Data.Maybe (fromMaybe)

import Data.IsTy
import Data.Proof.EQ

import LambdaCCC.Misc
import LambdaCCC.Ty
import LambdaCCC.CCC
import LambdaCCC.Lambda

{--------------------------------------------------------------------
    Conversion
--------------------------------------------------------------------}

-- | Rewrite a lambda expression via CCC combinators
toCCC :: E a -> (Unit :-> a)
toCCC = convert UnitP

toCCC' :: HasTy a => E (a :=> b) -> (a :-> b)
toCCC' (Lam p e) = convert p e
toCCC' e = toCCC' (Lam vp (e :^ ve))
 where
   (vp,ve) = vars "ETA"

-- | Convert @\ p -> e@ to CCC combinators
convert :: Pat a -> E b -> (a :-> b)
convert _ (Const o)  = Konst o
convert k (Var n t)  = fromMaybe (error $ "unbound variable: " ++ n) $
                       convertVar k n t
convert k (u :# v)   = convert k u &&& convert k v
convert k (u :^ v)   = Apply @. (convert k u &&& convert k v)
                  -- = Apply @. convert k (u :# v)
convert k (Lam p e)  = Curry (convert (PairP k p) e)

-- Convert a variable in context
convertVar :: Pat a -> Name -> Ty b -> Maybe (a :-> b)
convertVar (VarP x a) n b | x == n, Just Refl <- a `tyEq` b = Just Id
                          | otherwise = Nothing
convertVar UnitP _ _ = Nothing
convertVar (PairP p q) n b = 
  ((@. Snd) <$> convertVar q n b) `mplus` ((@. Fst) <$> convertVar p n b)

-- Note that we try q before p. This choice cooperates with uncurrying and
-- shadowing.