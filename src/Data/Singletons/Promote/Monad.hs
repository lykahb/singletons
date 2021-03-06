{- Data/Singletons/Promote/Monad.hs

(c) Richard Eisenberg 2014
eir@cis.upenn.edu

This file defines the PrM monad and its operations, for use during promotion.

The PrM monad allows reading from a PrEnv environment and writing to a list
of DDec, and is wrapped around a Q.
-}

{-# LANGUAGE GeneralizedNewtypeDeriving, StandaloneDeriving,
             FlexibleContexts, TypeFamilies, KindSignatures #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}   -- we have orphan Quasi instances

module Data.Singletons.Promote.Monad (
  PrM, promoteM, promoteM_, promoteMDecs, VarPromotions,
  allLocals, emitDecs, emitDecsM,
  lambdaBind, LetBind, letBind, lookupVarE
  ) where

import Control.Monad.Reader
import Control.Monad.Writer
import qualified Data.Map.Strict as Map
import Data.Map.Strict ( Map )
import Language.Haskell.TH.Syntax hiding ( lift )
import Language.Haskell.TH.Desugar
import Data.Singletons.Util
import Control.Applicative
import Data.Singletons.Names
import Data.Singletons.Syntax

type LetExpansions = Map Name DType  -- from **term-level** name

-- environment during promotion
data PrEnv =
  PrEnv { pr_lambda_bound :: Map Name Name
        , pr_let_bound    :: LetExpansions
        }

emptyPrEnv :: PrEnv
emptyPrEnv = PrEnv { pr_lambda_bound = Map.empty
                   , pr_let_bound    = Map.empty }

-- the promotion monad
newtype PrM a = PrM (ReaderT PrEnv (WriterT [DDec] Q) a)
  deriving ( Functor, Applicative, Monad, Quasi
           , MonadReader PrEnv, MonadWriter [DDec] )

-- we need Quasi instances for ReaderT and WriterT for the above to work.

instance (Quasi q, Monoid m) => Quasi (WriterT m q) where
  qNewName          = lift `comp1` qNewName
  qReport           = lift `comp2` qReport
  qLookupName       = lift `comp2` qLookupName
  qReify            = lift `comp1` qReify
  qReifyInstances   = lift `comp2` qReifyInstances
  qLocation         = lift qLocation
  qRunIO            = lift `comp1` qRunIO
  qAddDependentFile = lift `comp1` qAddDependentFile
  qReifyRoles       = lift `comp1` qReifyRoles
  qReifyAnnotations = lift `comp1` qReifyAnnotations
  qReifyModule      = lift `comp1` qReifyModule
  qAddTopDecls      = lift `comp1` qAddTopDecls
  qAddModFinalizer  = lift `comp1` qAddModFinalizer
  qGetQ             = lift qGetQ
  qPutQ             = lift `comp1` qPutQ

  qRecover handler body = do
    (result, aux) <- lift $ qRecover (runWriterT handler) (runWriterT body)
    tell aux
    return result

instance Quasi q => Quasi (ReaderT r q) where
  qNewName          = lift `comp1` qNewName
  qReport           = lift `comp2` qReport
  qLookupName       = lift `comp2` qLookupName
  qReify            = lift `comp1` qReify
  qReifyInstances   = lift `comp2` qReifyInstances
  qLocation         = lift qLocation
  qRunIO            = lift `comp1` qRunIO
  qAddDependentFile = lift `comp1` qAddDependentFile
  qReifyRoles       = lift `comp1` qReifyRoles
  qReifyAnnotations = lift `comp1` qReifyAnnotations
  qReifyModule      = lift `comp1` qReifyModule
  qAddTopDecls      = lift `comp1` qAddTopDecls
  qAddModFinalizer  = lift `comp1` qAddModFinalizer
  qGetQ             = lift qGetQ
  qPutQ             = lift `comp1` qPutQ

  qRecover handler body = do
    env <- ask
    lift $ qRecover (runReaderT handler env) (runReaderT body env)

-- return *type-level* names
allLocals :: MonadReader PrEnv m => m [Name]
allLocals = do
  lambdas <- asks (Map.toList . pr_lambda_bound)
  lets    <- asks pr_let_bound
    -- filter out shadowed variables!
  return [ typeName
         | (termName, typeName) <- lambdas
         , case Map.lookup termName lets of
             Just (DVarT typeName') | typeName' == typeName -> True
             _                                              -> False ]

emitDecs :: MonadWriter [DDec] m => [DDec] -> m ()
emitDecs = tell

emitDecsM :: MonadWriter [DDec] m => m [DDec] -> m ()
emitDecsM action = do
  decs <- action
  emitDecs decs

-- when lambda-binding variables, we still need to add the variables
-- to the let-expansion, because of shadowing. ugh.
lambdaBind :: VarPromotions -> PrM a -> PrM a
lambdaBind binds = local add_binds
  where add_binds env@(PrEnv { pr_lambda_bound = lambdas
                             , pr_let_bound    = lets }) =
          let new_lets = Map.fromList [ (tmN, DVarT tyN) | (tmN, tyN) <- binds ] in
          env { pr_lambda_bound = Map.union (Map.fromList binds) lambdas
              , pr_let_bound    = Map.union new_lets lets }

type LetBind = (Name, DType)
letBind :: [LetBind] -> PrM a -> PrM a
letBind binds = local add_binds
  where add_binds env@(PrEnv { pr_let_bound = lets }) =
          env { pr_let_bound = Map.union (Map.fromList binds) lets }

lookupVarE :: Name -> PrM DType
lookupVarE n = do
  lets <- asks pr_let_bound
  case Map.lookup n lets of
    Just ty -> return ty
    Nothing -> return $ promoteValRhs n

promoteM :: Quasi q => PrM a -> q (a, [DDec])
promoteM (PrM rdr) =
  let wr = runReaderT rdr emptyPrEnv
      q  = runWriterT wr
  in
  runQ q

promoteM_ :: Quasi q => PrM () -> q [DDec]
promoteM_ thing = do
  ((), decs) <- promoteM thing
  return decs

-- promoteM specialized to [DDec]
promoteMDecs :: Quasi q => PrM [DDec] -> q [DDec]
promoteMDecs thing = do
  (decs1, decs2) <- promoteM thing
  return $ decs1 ++ decs2
