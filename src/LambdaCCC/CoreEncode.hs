{-# LANGUAGE CPP #-}
{-# LANGUAGE ViewPatterns, PatternGuards #-}
{-# LANGUAGE FlexibleContexts, ConstraintKinds #-}
{-# LANGUAGE Rank2Types #-}
{-# OPTIONS_GHC -Wall #-}

{-# OPTIONS_GHC -fno-warn-unused-imports #-} -- TEMP
-- {-# OPTIONS_GHC -fno-warn-unused-binds   #-} -- TEMP

----------------------------------------------------------------------
-- |
-- Module      :  LambdaCCC.CoreEncode
-- Copyright   :  (c) 2014 Tabula, Inc.
-- 
-- Maintainer  :  conal@tabula.com
-- Stability   :  experimental
-- 
-- Transform away all non-standard types
----------------------------------------------------------------------

module LambdaCCC.CoreEncode where

-- TODO: explicit exports
import Prelude hiding (id,(.),(>>))
import qualified Prelude

import Control.Category (id,(.),(>>>))
import Control.Arrow (arr)
import Data.Functor ((<$),(<$>))
import Control.Applicative (liftA2)
import Data.Monoid (mempty)
import Data.List (intercalate)
import Data.Char (isUpper)

-- GHC
import PrelNames (eitherTyConName)

import HERMIT.Core (CoreDef(..),CoreProg)
import HERMIT.Dictionary hiding (externals) -- re-exports HERMIT.Dictionary.*
import HERMIT.External (External,ExternalName,external,(.+),CmdTag(Loop))
import HERMIT.GHC
import HERMIT.Kure
import HERMIT.Monad (saveDef,lookupDef,newIdH)
import HERMIT.Plugin (hermitPlugin,phase,interactive)

import HERMIT.Extras hiding (findTyConT)
import qualified HERMIT.Extras as Ex

import LambdaCCC.Misc ((<~))

{--------------------------------------------------------------------
    HERMIT tools
--------------------------------------------------------------------}

repr :: Role
repr = Representational

-- Use mempty instead okayN

-- Tighten the type of (>>). (Alternatively, choose a different operator.)
infixl 1 >>
(>>) :: Monad m => m () -> m b -> m b
(>>) = (Prelude.>>)

-- | \ x :: a -> (e `cast` co)  ==> (\ x -> e) `cast` (<a> -> co)
castFloatLamR :: ReExpr
castFloatLamR =
  do Lam x (e `Cast` co) <- id
     return $
       Lam x e `mkCast`
         mkFunCo repr (mkReflCo repr (varType x)) co

-- | case e of { Con -> rhs }  ==>  rhs
-- Warning: can gain definedness when e == _|_.
caseNoVarR :: ReExpr
caseNoVarR =
  do Case _ _ _ [(DataAlt _,[],rhs)] <- id
     return rhs

#if 0
cacheNameT :: (Functor m, Monad m, HasDynFlags m, Outputable a) =>
              Transform c m a String
cacheNameT = tweakName <$> showPprT
 where
   tweakName = intercalate "_" . map dropModules . words
   dropModules (c:rest) | not (isUpper c) = c : dropModules rest
   dropModules (break (== '.') -> (_,'.':rest)) = dropModules rest
   dropModules s = s

-- Build a dictionary for a given PredType, memoizing in the stash.
memoDict :: TransformH PredType CoreExpr
memoDict = memoR buildDictionaryT'

memoR :: Outputable a => Unop (TransformM c a CoreExpr)
memoR r = do lab <- cacheNameT
             constT (defExpr <$> lookupDef lab)
               <+ do e' <- r
                     v <- constT (newIdH lab (exprType e'))
                     constT (saveDef lab (Def v e'))
                     return (Let (NonRec v e') (Var v))
#endif

-- Build a dictionary for a given PredType, memoizing in the stash.
memoDict :: TransformH PredType CoreExpr
memoDict = do lab <- tweakName <$> showPprT
              constT (defExpr <$> lookupDef lab)
                <+ do dict <- buildDictionaryT'
                      -- Stash if non-trivial
                      ((isVarT $* dict) >> return dict)
                       <+ do v <- newIdT lab
                             constT (saveDef lab (Def v dict))
                             return (Let (NonRec v dict) (Var v))

-- Memoize a transformation. Don't introduce a let binding (for later floating),
-- which would interfere with additional simplification.
memoR :: Unop ReExpr
memoR r = do lab <- tweakName <$> showPprT
             constT (defExpr <$> lookupDef lab)
               <+ do e' <- r
                     saveDefNoFloat lab e'
                     return e'

-- More refactoring

tweakName :: Unop String
tweakName = intercalate "_" . map dropModules . words
 where
   dropModules (c:rest) | not (isUpper c) = c : dropModules rest
   dropModules (break (== '.') -> (_,'.':rest)) = dropModules rest
   dropModules s = s

defExpr :: CoreDef -> CoreExpr
defExpr (Def _ expr) = expr

{--------------------------------------------------------------------
    Observing
--------------------------------------------------------------------}

-- (Observing, observeR', triesL, labeled)

observing :: Ex.Observing
observing = False

-- #define LintDie

#ifdef LintDie
watchR :: String -> Unop ReExpr
watchR lab r = lintingExprR lab (labeled observing (lab,r)) -- hard error
#else
-- watchR lab r = labeledR lab r >>> lintExprR  -- Fail softly on core lint error.
watchR :: Injection a CoreTC =>
          String -> RewriteH a -> RewriteH a
watchR lab r = labeled observing (lab,r)  -- don't lint
#endif

skipT :: Monad m => Transform c m a b
skipT = fail "untried"

{--------------------------------------------------------------------
    Triviality
--------------------------------------------------------------------}

-- | Trivial expression: for now, literals, variables, casts of trivial.
trivialExpr :: FilterE
trivialExpr = setFailMsg "Non-trivial" $
              isTypeE <+ isVarT <+ isLitT
           <+ trivialLam
           <+ castT trivialExpr id mempty

trivialBind :: FilterH CoreBind
trivialBind = nonRecT successT trivialExpr mempty

trivialLet :: FilterE
trivialLet = letT trivialBind successT mempty

trivialLam :: FilterE
trivialLam = lamT id trivialExpr mempty

trivialBetaRedex :: FilterE
trivialBetaRedex = appT trivialLam successT mempty

-- These filters could instead be predicates. Then use acceptR.

letElimTrivialR :: ReExpr
letElimTrivialR = -- watchR "trivialLet" $
                  trivialLet >> letSubstR

betaReduceTrivial :: ReExpr
betaReduceTrivial = -- watchR "betaReduceTrivial" $
                    trivialBetaRedex >> betaReduceR

{--------------------------------------------------------------------
    Working with LambdaCCC.Encode
--------------------------------------------------------------------}

encName :: Unop String
encName = ("LambdaCCC.Encode." ++)

findTyConE :: String -> TransformH a TyCon
findTyConE = findTyConT . encName

appsE :: String -> [Type] -> [CoreExpr] -> TransformU CoreExpr
appsE = apps' . encName

-- A handy form for composition via <=< or =<<
appsE1 :: String -> [Type] -> CoreExpr -> TransformU CoreExpr
appsE1 str ts e = appsE str ts [e]

-- TODO: Try switching from TransformU

-- | Uncall a named function
unCallE :: String -> TransformH CoreExpr [CoreExpr]
unCallE = unCall . encName

-- | Uncall a named function
unCallE1 :: String -> ReExpr
unCallE1 = unCall1 . encName

-- | Uncall a named function of one dictionary and one other argument, dropping
-- the dictionary.
unCallD1 :: String -> ReExpr
unCallD1 f = do [_d,e] <- unCall f
                return e

unCallDE1 :: String -> ReExpr
unCallDE1 = unCallD1 . encName

{--------------------------------------------------------------------
    Super inlining
--------------------------------------------------------------------}

superInlineR :: ReExpr
superInlineR = -- watchR "superInlineR" $
               anytdE (repeatR inlineR')

-- superInlineR = watchR "superInlineR" $
--                bashUsingE (inlineR' : simplifiers)

inlineR' :: ReExpr
inlineR' = watchR "inlineR" inlineR

superInlineSimplifyR :: ReExpr
superInlineSimplifyR = memoR $
                       simplifyAll . superInlineR

-- TODO: Memoize superInlineR

{--------------------------------------------------------------------
    Standard types
--------------------------------------------------------------------}

-- TODO: Parametrize the rest of the module by 'standardTyT'.

-- TODO: Consider how to eliminate Encode as well. Then simplify to
-- standardTy :: Type -> Bool

-- A "standard type" is built up from `Unit`, `Bool`, `Int` (for now), pairs (of
-- standard types), sums, and functions, or Encode

standardTyT :: FilterTy
standardTyT =
     tyConAppT (acceptR standardTC) (const standardTyT) mempty
  <+ (funTyT standardTyT standardTyT mempty)
  <+ (standardTyT . tcViewT)
  <+ fail "standardTyT: not"

-- standardTyT (tcView -> Just ty) = standardTyT ty
-- standardTyT (TyConApp tc args) | standardTC tc
--                                = mapM_ standardTyT args
-- standardTyT ty@(TyConApp tc _) =
--   -- Treat Encode applications as standard.
--   do encodeTC <- findTyConT "LambdaCCC.Encode.Encode"
--      if tc == encodeTC then successT else nonStandardFail ty
-- standardTyT (FunTy arg res) =
--   standardTyT arg >> standardTyT res
-- standardTyT ty = nonStandardFail ty

standardTC :: TyCon -> Bool
standardTC tc =
     (tc `elem` [unitTyCon, boolTyCon, intTyCon])
  || isPairTC tc
  || tyConName tc == eitherTyConName    -- no eitherTyCon

nonStandardFail :: FilterTy
nonStandardFail =
  do s <- showPprT
     fail ("non-standard type:\n" ++ s)

nonStandardTyT :: FilterTy
nonStandardTyT = notM standardTyT

nonStandardE :: FilterE
nonStandardE = isTypeE <+ (nonStandardTyT . arr exprType')

-- TODO: Maybe I just want a standard outer shell.

-- TODO: Maybe use coreView instead of tcView? I think it's tcView we want,
-- since it just looks through type synonyms and not newtypes.

-- TODO: If I remove Encode, standardTy can be Type -> Bool

{--------------------------------------------------------------------
    Simple Encode/Encodable wrapping/unwrapping
--------------------------------------------------------------------}

tyConApp1 :: TyCon -> Type -> Type
tyConApp1 tc t = TyConApp tc [t]

tyConAppE1 :: String -> ReType
tyConAppE1 name = do tc <- findTyConE name
                     arr (tyConApp1 tc)

-- t ==> Encode t
encodeTyR :: ReType
encodeTyR = tyConAppE1 "Encode"

-- t ==> Encodable t
encodableR :: ReType
encodableR = tyConAppE1 "Encodable"

encodeDictT :: TransformH Type CoreExpr
encodeDictT = memoDict . encodableR
-- encodeDictT = buildDictionaryT' . encodableR

encodeR :: ReExpr
encodeR = -- nonStandardE >>
          do e <- idR
             let ty = exprType e
             dict <- encodeDictT $* ty
             appsE "encode" [ty] [dict,e]

decodeR :: ReExpr
decodeR = cleanupUnfoldR .
          appAllR squashCode id .
          do e    <- idR
             ty   <- unEncodeTy $* exprType e
             dict <- encodeDictT $* ty
             appsE "decode" [ty] [dict,e]

-- recodeR :: ReExpr
-- recodeR = do e <- idR
--              let ty = exprType e
--              dict <- encodeDictT $* ty
--              appsE "recode" [ty] [dict,e]

-- TODO: refactor, and consider making apps' and apps1' into non-U transforms.

-- Alternatively,

-- | e ==> recode e ==> decode (encode e), and inline & simplify decode.
recodeR :: ReExpr
recodeR = -- watchR "recodeR" $
          decodeR . encodeR

-- inlineDecodeR :: ReExpr
-- inlineDecodeR = appAllR (isDecode >> squashCode) id

-- -- | e ==> recode e, with a simplified type-specialized recode
-- recodeSquashR :: ReExpr
-- recodeSquashR = watchR "recodeSquashR" $
--                 nonStandardE >>
--                 (recodeR >>> appAllR squashCode id)

-- encode a ==> a
unEncode :: ReExpr
unEncode = unCallDE1 "encode"
-- decode b ==> b
unDecode :: ReExpr
unDecode = unCallDE1 "decode"

-- encode (decode e) ==> e
encodeDecode :: ReExpr
encodeDecode = unEncode >>> unDecode

-- isEncode :: Type -> Bool
-- isEncode (TyConApp (tyConName -> name) [_]) = uqName name == "encode"
-- isEncode _                                  = False

unEncodeTy :: ReType
unEncodeTy =
  tyConApp1T (acceptR ((== "Encode") . uqName . tyConName)) id (const id)

-- Rewrite inside of encode applications
inEncode :: Unop ReExpr
inEncode = encodeR <~ unEncode

-- Avoid constructing a new dictionary
-- inEncode r =
--   unEncode >>
--   appAllR id (appAllR id (appAllR id r))  -- encode t dict e

-- -- | Recognize encode with type and dictionary arguments.
-- isEncode :: FilterE
-- isEncode = unEncode >>> mempty

squashCode :: ReExpr
squashCode =
  do (_,[_ty,_dict])
       <- callPredT (flip (const ((`elem` squashNames) . fqVarName)))
     superInlineR
 where
   squashNames = encName <$> [ "encode","decode","recode" ]

{--------------------------------------------------------------------
    Encode transformations
--------------------------------------------------------------------}

-- | Is a variable applied to zero or more types
isVarTyAppsT :: FilterE
isVarTyAppsT = isVarT <+ appT isVarTyAppsT isTypeE mempty

-- isVarTyAppsT = do { (Var _,_,[]) <- callSplitT ; return () }

encodeVar :: ReExpr
encodeVar = (unEncode >>> isVarTyAppsT) >>
            appAllR superInlineSimplifyR id

-- encodeVar =
--   inEncode $
--     do (Var _,_,[]) <- callSplitT
--        unfoldR >>> tryR simplifyAll

-- TODO: Cache!

-- | encode (u v)  ==> (encode u `cast` (Encode a -> Encode b)) (encode v)
-- where u :: a -> b, v :: a.
encodeDistribApp :: ReExpr
encodeDistribApp =
  do encB <- exprTypeT  -- Encode b
     unEncode >>>
       appT encodeR encodeR (\ encU encV ->
         let encA = exprType' encV
             -- Coerce encU from Encode (ta -> tb) to (Encode ta -> Encode tb).
             co = mkUnivCo repr
                    (exprType' encU) (mkFunTy encA encB)
           in
             App (Cast encU co) encV)

encodeLamR :: ReExpr
encodeLamR = (unEncode >>> lamT id id mempty) >>
             (cleanupUnfoldR . appAllR squashCode id)

-- TODO: Use legit coercion.

-- unfolds :: ReExpr
-- unfolds = watchR "unfolds" $
--           unfoldNamesR $
--   encName <$> ["encode","recode","recode","(-->)"] ++
--   []

-- TODO: For more flexibility, split the transformation in two pieces:
-- 
--    (,) ta' tb (a `cast` coa) b ==> (,) ta tb a b `cast` coab
-- 
-- where `coa :: ta ~R ta'`, and `coab :: (ta,tb) ~R (ta',tb)`.
-- Similarly for tb'.

-- mkTyConAppCo :: Role -> TyCon -> [Coercion] -> Coercion

-- callNameT :: MonadCatch m => String -> Transform c m CoreExpr (CoreExpr, [CoreExpr])

-- | case e of alts  ==>  case recode e of alts
-- Warning, can loop. Must simplify.
recodeScrutineeR :: ReExpr
recodeScrutineeR = caseAllR recodeR id id (const id)

-- caseAllR :: (ExtendPath c Crumb, ReadPath c Crumb, AddBindings c, Monad m)
--          => Rewrite c m CoreExpr
--          -> Rewrite c m Id
--          -> Rewrite c m Type
--          -> (Int -> Rewrite c m CoreAlt)
--          -> Rewrite c m CoreExpr

{--------------------------------------------------------------------
    Put it together
--------------------------------------------------------------------}

encoders :: [ReExpr]
encoders =
  [ watchR "encodeVar" encodeVar
  , watchR "encodeDistribApp" encodeDistribApp
  , watchR "encodeLamR" encodeLamR
  -- , watchR "recodeScrutineeR" recodeScrutineeR
  ] 

oneEncode :: ReExpr
oneEncode = orR encoders

encodePass :: ReCore
encodePass = watchR "encodePass" $
             anytdR (promoteR oneEncode)

-- simplifyOne :: ReExpr
-- simplifyOne = orR simplifiers
-- -- simplifyOne = foldr (<+) (fail "standardize: nothing to do here") simplifiers

#define UseBash

simplifyAll :: ReExpr

simplifiers :: [ReExpr]
simplifiers =
  [ watchR "letElimTrivialR" letElimTrivialR
  -- , watchR "betaReduceTrivial" betaReduceTrivial
  , watchR "letElimR" letElimR   -- removed unused bindings after inlining
  , watchR "castFloatAppR'" castFloatAppR'
  , watchR "castCastR" castCastR
  , watchR "lamFloatCastR" lamFloatCastR
  -- , watchR "castFloatLamR" castFloatLamR
  -- , watchR "caseReduceR" (caseReduceR False)  -- let rather than subst  ??
  -- , watchR "castFloatCaseR" castFloatCaseR
  , watchR "pairCastR" pairCastR
  , watchR "caseNoVarR" caseNoVarR
  ]
#ifndef UseBash
  ++ bashSimplifiers

-- From bashComponents.
bashSimplifiers :: [ReExpr]
bashSimplifiers =
  [ watchR "betaReduceR" betaReduceR
  , watchR "(caseReduceR True)" (caseReduceR True)
  , watchR "(caseReduceIdR True)" (caseReduceIdR True)
  , watchR "caseElimSeqR" caseElimSeqR
  , watchR "unfoldBasicCombinatorR" unfoldBasicCombinatorR
  , watchR "inlineCaseAlternativeR" inlineCaseAlternativeR
  , watchR "etaReduceR" etaReduceR
  -- letNonRecSubstSafeR was undoing my dictionary `let` bindings.
  -- , watchR "letNonRecSubstSafeR" letNonRecSubstSafeR
  , watchR "caseFloatAppR" caseFloatAppR
  , watchR "caseFloatCaseR" caseFloatCaseR
  , watchR "caseFloatLetR" caseFloatLetR
  , watchR "caseFloatCastR" caseFloatCastR  -- Watch this one
  , watchR "letFloatAppR" letFloatAppR
  , watchR "letFloatArgR" letFloatArgR
  , watchR "letFloatLamR" letFloatLamR
  , watchR "letFloatLetR" letFloatLetR
  , watchR "letFloatCaseR" letFloatCaseR
  , watchR "letFloatCastR" letFloatCastR
  , watchR "castElimReflR" castElimReflR
  , watchR "castElimSymR" castElimSymR
  ]

simplifyAll = watchR "simplifyAll" $
              bashUsingE (promoteR <$> simplifiers)

#else

simplifyAll = watchR "simplifyAll" $
              bashExtendedWithE (promoteR <$> simplifiers)

#endif

simplifyOne :: ReExpr
simplifyOne = orR simplifiers
-- simplifyOne = foldr (<+) (fail "standardize: nothing to do here") simplifiers

simplifyAllRhs :: RewriteH CoreProg
simplifyAllRhs = progRhsAnyR simplifyAll

{--------------------------------------------------------------------
    Plugin
--------------------------------------------------------------------}

plugin :: Plugin
plugin = hermitPlugin (phase 0 . interactive externals)

externals :: [External]
externals =
    [ externC "simplify-one" simplifyOne
        "Locally simplify for normalization, without inlining"
    , externC "simplify-all" simplifyAll "Bash with normalization simplifiers (no inlining)"
    , externC "simplify-all-rhs" simplifyAllRhs "simplify-all on all top-level RHSs"
    , externC "encode-pass" encodePass "a single top-down encoding pass"
    , externC "encode-distrib-app" encodeDistribApp
        "encode (u v) ==> (encode u) (encode v)"
    , externC "encode-lam" encodeLamR "Encode a lambda"
    , externC "encode-var" encodeVar "Encode a variable applied to zero or more types"
    , externC "unencode" unEncode "drop encode application"
    , externC "encode" encodeR "e ==> encode e"
    , externC "decode" decodeR "e ==> decode e"
    , externC "recode" recodeR "e ==> recode e"
    , externC "super-inline" superInlineR "Transitive inlining with bash"
    , externC "squash-code" squashCode "super-inline on encode-related"
--     , externC "unfolds" unfolds "Misc unfoldings for type encoding"
    , externC "recode-scrutinee" recodeScrutineeR "Recode case scrutinee"
    -- Move to HERMIT.Extras:
    , externC "dump-stash" dumpStashR "Dump the stash into the program"
    , externC "drop-stashed-let" dropStashedLetR "..."
    , externC "cast-float-case" castFloatCaseR
        "Float cast upward through case. Inverse to 'caseFloatCastR', so don't use both rules!"
    , externC "pair-cast" pairCastR
        "(,) ta' tb' (a `cast` coa) (b `cast` cob) ==> (,) ta tb a b `cast` coab"
    , externC "cast-float-app'" castFloatAppR' "cast-float-app with transitivity"
    , externC "cast-cast" castCastR "Coalesce nested casts"
    , externC "un-cast-cast" unCastCastR "Uncoalesce to nested casts"
    , externC "lam-float-cast" lamFloatCastR "Float lambda through cast"
    , externC "cast-float-lam" castFloatLamR "Float cast through lambda"
    , externC "simplify-expr" simplifyExprR "Invoke GHC's simplifyExpr"
    , externC "case-wild" caseWildR "case of wild ==> let (doesn't preserve evaluation)"
    , external "repeat" (repeatN :: Int -> Unop (RewriteH Core))
       [ "Repeat a rewrite n times." ] .+ Loop
    ]
