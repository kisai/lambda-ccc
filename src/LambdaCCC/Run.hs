{-# LANGUAGE TypeOperators, ConstraintKinds, FlexibleContexts #-}
{-# LANGUAGE CPP #-}

{-# OPTIONS_GHC -Wall #-}

{-# OPTIONS_GHC -fno-warn-unused-imports #-} -- TEMP
-- {-# OPTIONS_GHC -fno-warn-unused-binds   #-} -- TEMP

----------------------------------------------------------------------
-- |
-- Module      :  Run
-- Copyright   :  (c) 2014 Tabula, Inc.
-- 
-- Maintainer  :  conal@tabula.com
-- Stability   :  experimental
-- 
-- Run a test: reify, CCC, circuit
----------------------------------------------------------------------

module LambdaCCC.Run (go,run) where

import Prelude

import LambdaCCC.Misc (Unop)
import LambdaCCC.Lambda (EP,reifyEP)
import LambdaCCC.CCC ((:->),convertC)
import LambdaCCC.ToCCC (toCCC')

import Circat.Circuit (GenBuses,(:>),outGWith)
import Circat.Netlist (outV)

go :: GenBuses a => String -> (a -> b) -> IO ()
go name f = run name (reifyEP f)
{-# INLINE go #-}

-- #define ViaTerm

-- Run an example: reify, CCC, circuit.
run :: GenBuses a => String -> EP (a -> b) -> IO ()
#ifdef ViaTerm
run str  expr = do print expr
                   print term
                   outGV str circ
 where
   term = toCCC' expr
   circ = convertC term
#else
run str  e = do print e
                print (idCT (toCCC' e))
                outGV str (toCCC' e)

-- Identity on CCC terms
idCT :: Unop (a :-> b)
idCT = id
#endif

-- Diagram and Verilog
outGV :: GenBuses a => String -> (a :> b) -> IO ()
outGV s c = do 
               outGWith ("pdf","")      s c
--             outGWith ("svg","")      s c
--             outGWith ("png","-Gdpi=200") s c
               outV                     s c
