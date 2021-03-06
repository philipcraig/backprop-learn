{-# LANGUAGE AllowAmbiguousTypes     #-}
{-# LANGUAGE ConstraintKinds         #-}
{-# LANGUAGE DataKinds               #-}
{-# LANGUAGE FlexibleContexts        #-}
{-# LANGUAGE FlexibleInstances       #-}
{-# LANGUAGE FunctionalDependencies  #-}
{-# LANGUAGE GADTs                   #-}
{-# LANGUAGE KindSignatures          #-}
{-# LANGUAGE MultiParamTypeClasses   #-}
{-# LANGUAGE PatternSynonyms         #-}
{-# LANGUAGE ScopedTypeVariables     #-}
{-# LANGUAGE TupleSections           #-}
{-# LANGUAGE TypeFamilies            #-}
{-# LANGUAGE TypeFamilyDependencies  #-}
{-# LANGUAGE TypeInType              #-}
{-# LANGUAGE TypeOperators           #-}
{-# LANGUAGE UndecidableInstances    #-}
{-# LANGUAGE UndecidableSuperClasses #-}

module Backprop.Learn.Model.Class (
    Learn(..)
  , LParam, LState, LParams, LStates, NoParam, NoState
  , LParam_, LState_
  , stateless, statelessM
  , runLearnStateless
  , runLearnStochStateless
  , Mayb(..), fromJ_, MaybeC, KnownMayb, knownMayb, I(..)
  , SomeLearn(..)
  ) where

import           Backprop.Learn.Initialize
import           Control.DeepSeq
import           Control.Monad.Primitive
import           Data.Kind
import           Data.Type.Mayb
import           Data.Typeable
import           Numeric.Backprop
import           Numeric.Opto.Update
import           Type.Family.List          (type (++))
import qualified GHC.TypeLits              as TL
import qualified System.Random.MWC         as MWC

-- | The trainable parameter type of a model.  Will be a compile-time error
-- if the model has no trainable parameters.
type LParam l = FromJust
    ('TL.ShowType l 'TL.:<>: 'TL.Text " has no trainable parameters")
    (LParamMaybe l)

-- | The state type of a model.  Will be a compile-time error if the model
-- has no state.
type LState l = FromJust
    ('TL.ShowType l 'TL.:<>: 'TL.Text " has no trainable parameters")
    (LStateMaybe l)

-- | Constraint specifying that a given model has no trainabale parameters.
type NoParam l = LParamMaybe l ~ 'Nothing

-- | Constraint specifying that a given model has no state.
type NoState l = LStateMaybe l ~ 'Nothing

-- | Is 'N_' if there is @l@ has no trainable parameters; otherwise is 'J_'
-- with @f p@, for trainable parameter type @p@.
type LParam_ f l = Mayb f (LParamMaybe l)

-- | Is 'N_' if there is @l@ has no state; otherwise is 'J_' with @f
-- s@, for state type @s@.
type LState_ f l = Mayb f (LStateMaybe l)

-- | List of parameters of 'Learn' instances
type family LParams (ls :: [Type]) :: [Type] where
    LParams '[]       = '[]
    LParams (l ': ls) = MaybeToList (LParamMaybe l) ++ LParams ls

-- | List of states of 'Learn' instances
type family LStates (ls :: [Type]) :: [Type] where
    LStates '[]       = '[]
    LStates (l ': ls) = MaybeToList (LStateMaybe l) ++ LStates ls

-- | Class for models that can be trained using gradient descent
--
-- An instance @l@ of @'Learn' a b@ is parameterized by @p@, takes @a@ as
-- input, and returns @b@ as outputs.  @l@ can be thought of as a value
-- containing the /hyperparmaeters/ of the model.
class Learn a b l | l -> a b where

    -- | The trainable parameters of model @l@.
    --
    -- By default, is ''Nothing'.  To give a type for learned parameters @p@,
    -- use the type @''Just' p@
    type LParamMaybe l :: Maybe Type

    -- | The type of the state of model @l@.  Used for things like
    -- recurrent neural networks.
    --
    -- By default, is ''Nothing'.  To give a type for state @s@, use the
    -- type @''Just' s@.
    --
    -- Most models will not use state, training algorithms will only work
    -- if 'LStateMaybe' is ''Nothing'.  However, models that use state can
    -- be converted to models that do not using 'Unroll'; this can be done
    -- before training.
    type LStateMaybe l :: Maybe Type

    type LParamMaybe l = 'Nothing
    type LStateMaybe l = 'Nothing

    -- | Run the model itself, deterministically.
    --
    -- If your model has no state, you can define this conveniently using
    -- 'stateless'.
    runLearn
        :: Reifies s W
        => l
        -> LParam_ (BVar s) l
        -> BVar s a
        -> LState_ (BVar s) l
        -> (BVar s b, LState_ (BVar s) l)

    -- | Run a model in stochastic mode.
    --
    -- If model is inherently non-stochastic, a default implementation is
    -- given in terms of 'runLearn'.
    --
    -- If your model has no state, you can define this conveniently using
    -- 'statelessStoch'.
    runLearnStoch
        :: (Reifies s W, PrimMonad m)
        => l
        -> MWC.Gen (PrimState m)
        -> LParam_ (BVar s) l
        -> BVar s a
        -> LState_ (BVar s) l
        -> m (BVar s b, LState_ (BVar s) l)
    runLearnStoch l _ p x s = pure (runLearn l p x s)

-- | Useful for defining 'runLearn' if your model has no state.
stateless
    :: (a -> b)
    -> (a -> s -> (b, s))
stateless f x = (f x,)

-- | Useful for defining 'runLearnStoch' if your model has no state.
statelessM
    :: Functor m
    => (a -> m b)
    -> (a -> s -> m (b, s))
statelessM f x s = (, s) <$> f x

runLearnStateless
    :: (Learn a b l, Reifies s W, NoState l)
    => l
    -> LParam_ (BVar s) l
    -> BVar s a
    -> BVar s b
runLearnStateless l p = fst . flip (runLearn l p) N_

runLearnStochStateless
    :: (Learn a b l, Reifies s W, NoState l, PrimMonad m)
    => l
    -> MWC.Gen (PrimState m)
    -> LParam_ (BVar s) l
    -> BVar s a
    -> m (BVar s b)
runLearnStochStateless l g p = fmap fst . flip (runLearnStoch l g p) N_

-- | Existential wrapper for learnable model, representing a trainable
-- function from @a@ to @b@.
data SomeLearn :: Type -> Type -> Type where
    SL :: ( Learn a b l
          , Typeable l
          , KnownMayb (LParamMaybe l)
          , KnownMayb (LStateMaybe l)
          , MaybeC Floating (LParamMaybe l)
          , MaybeC Floating (LStateMaybe l)
          , MaybeC (Metric Double) (LParamMaybe l)
          , MaybeC (Metric Double) (LStateMaybe l)
          , MaybeC NFData (LParamMaybe l)
          , MaybeC NFData (LStateMaybe l)
          , MaybeC Initialize (LParamMaybe l)
          , MaybeC Initialize (LStateMaybe l)
          )
       => l
       -> SomeLearn a b

