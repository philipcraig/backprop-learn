{-# LANGUAGE DataKinds  #-}
{-# LANGUAGE GADTs      #-}
{-# LANGUAGE PolyKinds  #-}
{-# LANGUAGE RankNTypes #-}

module Learn.Neural.Loss (
    LossFunction
  , crossEntropy
  , squaredError
  ) where

import           GHC.TypeLits
import           Numeric.BLAS
import           Numeric.Backprop

type LossFunction s = forall b q. (BLAS b, Num (b s)) => b s -> OpB q '[ b s ] '[ Scalar b ]

crossEntropy :: KnownNat n => LossFunction '[n]
crossEntropy targ = bpOp . withInps $ \(r :< Ø) -> do
    logR <- tmapOp log ~$ (r :< Ø)
    res  <- negate <$> (dotOp ~$ (logR :< t :< Ø))
    only <$> bindVar res
  where
    t = constVar targ

squaredError :: KnownNat n => LossFunction '[n]
squaredError targ = bpOp . withInps $ \(r :< Ø) -> do
    err  <- bindVar $ r - t
    only <$> (dotOp ~$ (err :< err :< Ø))
  where
    t = constVar targ

