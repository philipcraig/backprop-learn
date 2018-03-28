{-# LANGUAGE AllowAmbiguousTypes    #-}
{-# LANGUAGE ConstraintKinds        #-}
{-# LANGUAGE DataKinds              #-}
{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE GADTs                  #-}
{-# LANGUAGE KindSignatures         #-}
{-# LANGUAGE LambdaCase             #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE RankNTypes             #-}
{-# LANGUAGE ScopedTypeVariables    #-}
{-# LANGUAGE TupleSections          #-}
{-# LANGUAGE TypeApplications       #-}
{-# LANGUAGE TypeFamilies           #-}
{-# LANGUAGE TypeFamilyDependencies #-}
{-# LANGUAGE TypeInType             #-}
{-# LANGUAGE TypeOperators          #-}
{-# LANGUAGE UndecidableInstances   #-}
{-# LANGUAGE ViewPatterns           #-}

module Backprop.Learn.Component.Combinator (
    Chain(..)
  , (~++)
  , chainParamLength
  , chainStateLength
  , LearnFunc(..), learnFunc
  , (.~)
  , nilLF, onlyLF
  ) where

import           Backprop.Learn.Class
import           Control.Applicative
import           Control.Category
import           Control.Monad
import           Control.Monad.Primitive
import           Data.Bifunctor
import           Data.Kind
import           Data.Type.Equality
import           Data.Type.Length
import           Data.Type.Mayb                    as Mayb
import           Data.Type.NonEmpty
import           Numeric.Backprop
import           Numeric.Backprop.Tuple
import           Prelude hiding                    ((.), id)
import           Type.Class.Higher
import           Type.Class.Known
import           Type.Class.Witness
import           Type.Family.List                  as List
import qualified System.Random.MWC                 as MWC

-- | Chain components linearly, retaining the ability to deconstruct at
-- a later time.
data Chain :: [Type] -> [Type] -> [Type] -> Type -> Type -> Type where
    CNil  :: Chain '[] '[] '[] a a
    (:~>) :: (Learn a b l, KnownMayb (LParamMaybe l), KnownMayb (LStateMaybe l))
          => l
          -> Chain ls        ps ss b c
          -> Chain (l ': ls) (MaybeToList (LParamMaybe l) ++ ps)
                             (MaybeToList (LStateMaybe l) ++ ss)
                             a c
infixr 5 :~>

instance ( ListC (Num List.<$> ps), ListC (Num List.<$> ss) )
      => Learn a b (Chain ls ps ss a b) where
    type LParamMaybe (Chain ls ps ss a b) = NETup Mayb.<$> ToNonEmpty ps
    type LStateMaybe (Chain ls ps ss a b) = NETup Mayb.<$> ToNonEmpty ss

    initParam     = initChainParam
    initState     = initChainState
    runLearn      = runChainLearn
    runLearnStoch = runChainLearnStoch


initChainParam
    :: forall ls ps ss a b m. PrimMonad m
    => Chain ls ps ss a b
    -> MWC.Gen (PrimState m)
    -> Mayb m (NETup Mayb.<$> ToNonEmpty ps)
initChainParam = \case
    CNil -> \_ -> N_
    (l :: l) :~> ls -> case knownMayb @(LParamMaybe l) of
      N_   -> initChainParam ls
      J_ _ -> \g -> J_ $ do
        q <- fromJ_ $ initParam l g
        case chainParamLength ls of
          LZ   -> pure $ NET q TNil
          LS _ -> NET q . netT <$> fromJ_ (initChainParam ls g)

initChainState
    :: forall ls ps ss a b m. PrimMonad m
    => Chain ls ps ss a b
    -> MWC.Gen (PrimState m)
    -> Mayb m (NETup Mayb.<$> ToNonEmpty ss)
initChainState = \case
    CNil -> \_ -> N_
    (l :: l) :~> ls -> case knownMayb @(LStateMaybe l) of
      N_   -> initChainState ls
      J_ _ -> \g -> J_ $ do
        q <- fromJ_ $ initState l g
        case chainStateLength ls of
          LZ   -> pure $ NET q TNil
          LS _ -> NET q . netT <$> fromJ_ (initChainState ls g)

runChainLearn
    :: (Reifies s W, ListC (Num List.<$> ps), ListC (Num List.<$> ss))
    => Chain ls ps ss a b
    -> Mayb (BVar s) (NETup Mayb.<$> ToNonEmpty ps)
    -> BVar s a
    -> Mayb (BVar s) (NETup Mayb.<$> ToNonEmpty ss)
    -> (BVar s b, Mayb (BVar s) (NETup Mayb.<$> ToNonEmpty ss))
runChainLearn = \case
  CNil -> \_ x _ -> (x, N_)
  (l :: l) :~> ls ->
    let lenPs = chainParamLength ls
        lenSs = chainStateLength ls
    in case knownMayb @(LParamMaybe l) of
      N_ -> \ps x -> case knownMayb @(LStateMaybe l) of
        N_ -> \ss -> flip (runChainLearn ls ps) ss
                   . runLearnStateless l N_
                   $ x
        J_ _ -> case lenSs of
          LZ -> \case
            J_ (isoVar (tOnly . netT) (tNet . onlyT)->s) ->
              let (y, J_ s') = runLearn      l  N_ x (J_ s)
                  (z, _    ) = runChainLearn ls ps y N_
              in  (z, J_ $ isoVar (tNet . onlyT) (tOnly . netT) s')
          LS _ -> \case
            J_ ss -> lenSs //
              let (y, J_ s' ) = runLearn      l  N_ x (J_ (ss ^^. netHead))
                  ssTail      = isoVar tNet netT $ ss ^^. netTail
                  (z, J_ ss') = runChainLearn ls ps y (J_ ssTail)
              in  (z, J_ $ isoVar2 NET unNet s' $ isoVar netT tNet ss')
      J_ _ -> case lenPs of
        LZ -> \case
          J_ (isoVar (tOnly . netT) (tNet . onlyT)->p) -> \x -> case knownMayb @(LStateMaybe l) of
            N_ -> \ss -> flip (runChainLearn ls N_) ss
                       . runLearnStateless l (J_ p)
                       $ x
            J_ _ -> case lenSs of
              LZ -> \case
                J_ (isoVar (tOnly . netT) (tNet . onlyT)->s) ->
                  let (y, J_ s') = runLearn      l  (J_ p)  x (J_ s)
                      (z, _    ) = runChainLearn ls N_      y N_
                  in  (z, J_ $ isoVar (tNet . onlyT) (tOnly . netT) s')
              LS _ -> \case
                J_ ss -> lenSs //
                  let (y, J_ s' ) = runLearn      l  (J_ p) x (J_ (ss ^^. netHead))
                      ssTail      = isoVar tNet netT $ ss ^^. netTail
                      (z, J_ ss') = runChainLearn ls N_     y (J_ ssTail)
                  in  (z, J_ $ isoVar2 NET unNet s' $ isoVar netT tNet ss')
        LS _ -> \case
          J_ ps -> \x -> lenPs //
            let psHead = ps ^^. netHead
                psTail = isoVar tNet netT $ ps ^^. netTail
            in  case knownMayb @(LStateMaybe l) of
                  N_ -> \ss -> flip (runChainLearn ls (J_ psTail)) ss
                             . runLearnStateless l (J_ psHead)
                             $ x
                  J_ _ -> case lenSs of
                    LZ -> \case
                      J_ (isoVar (tOnly . netT) (tNet . onlyT)->s) ->
                        let (y, J_ s') = runLearn      l  (J_ psHead) x (J_ s)
                            (z, _    ) = runChainLearn ls (J_ psTail) y N_
                        in  (z, J_ $ isoVar (tNet . onlyT) (tOnly . netT) s')
                    LS _ -> \case
                      J_ ss -> lenSs //
                        let (y, J_ s' ) = runLearn      l  (J_ psHead) x (J_ (ss ^^. netHead))
                            ssTail      = isoVar tNet netT $ ss ^^. netTail
                            (z, J_ ss') = runChainLearn ls (J_ psTail) y (J_ ssTail)
                        in  (z, J_ $ isoVar2 NET unNet s' $ isoVar netT tNet ss')


runChainLearnStoch
    :: (Reifies s W, ListC (Num List.<$> ps), ListC (Num List.<$> ss), PrimMonad m)
    => Chain ls ps ss a b
    -> MWC.Gen (PrimState m)
    -> Mayb (BVar s) (NETup Mayb.<$> ToNonEmpty ps)
    -> BVar s a
    -> Mayb (BVar s) (NETup Mayb.<$> ToNonEmpty ss)
    -> m (BVar s b, Mayb (BVar s) (NETup Mayb.<$> ToNonEmpty ss))
runChainLearnStoch = \case
  CNil -> \_ _ x _ -> pure (x, N_)
  (l :: l) :~> ls -> \g ->
    let lenPs = chainParamLength ls
        lenSs = chainStateLength ls
    in case knownMayb @(LParamMaybe l) of
      N_ -> \ps x -> case knownMayb @(LStateMaybe l) of
        N_ -> \ss -> flip (runChainLearnStoch ls g ps) ss
                 <=< runLearnStochStateless l g N_
                   $ x
        J_ _ -> case lenSs of
          LZ -> \case
            J_ (isoVar (tOnly . netT) (tNet . onlyT)->s) -> do
              (y, s') <- second fromJ_
                     <$> runLearnStoch      l  g N_ x (J_ s)
              (z, _ ) <- runChainLearnStoch ls g ps y N_
              pure (z, J_ $ isoVar (tNet . onlyT) (tOnly . netT) s')
          LS _ -> \case
            J_ ss -> lenSs // do
              (y, s' ) <- second fromJ_
                      <$> runLearnStoch      l  g N_ x (J_ (ss ^^. netHead))
              let ssTail = isoVar tNet netT $ ss ^^. netTail
              (z, ss') <- second fromJ_
                      <$> runChainLearnStoch ls g ps y (J_ ssTail)
              pure  (z, J_ $ isoVar2 NET unNet s' $ isoVar netT tNet ss')
      J_ _ -> case lenPs of
        LZ -> \case
          J_ (isoVar (tOnly . netT) (tNet . onlyT)->p) -> \x -> case knownMayb @(LStateMaybe l) of
            N_ -> \ss -> flip (runChainLearnStoch ls g N_) ss
                     <=< runLearnStochStateless l g (J_ p)
                       $ x
            J_ _ -> case lenSs of
              LZ -> \case
                J_ (isoVar (tOnly . netT) (tNet . onlyT)->s) -> do
                  (y, s') <- second fromJ_
                         <$> runLearnStoch      l  g (J_ p)  x (J_ s)
                  (z, _ ) <- runChainLearnStoch ls g N_      y N_
                  pure (z, J_ $ isoVar (tNet . onlyT) (tOnly . netT) s')
              LS _ -> \case
                J_ ss -> lenSs // do
                  (y, s' ) <- second fromJ_
                          <$> runLearnStoch      l  g (J_ p) x (J_ (ss ^^. netHead))
                  let ssTail = isoVar tNet netT $ ss ^^. netTail
                  (z, ss') <- second fromJ_
                          <$> runChainLearnStoch ls g N_     y (J_ ssTail)
                  pure (z, J_ $ isoVar2 NET unNet s' $ isoVar netT tNet ss')
        LS _ -> \case
          J_ ps -> \x -> lenPs //
            let psHead = ps ^^. netHead
                psTail = isoVar tNet netT $ ps ^^. netTail
            in  case knownMayb @(LStateMaybe l) of
                  N_ -> \ss -> flip (runChainLearnStoch ls g (J_ psTail)) ss
                           <=< runLearnStochStateless l g (J_ psHead)
                             $ x
                  J_ _ -> case lenSs of
                    LZ -> \case
                      J_ (isoVar (tOnly . netT) (tNet . onlyT)->s) -> do
                        (y, s') <- second fromJ_
                               <$> runLearnStoch      l  g (J_ psHead) x (J_ s)
                        (z, _ ) <- runChainLearnStoch ls g (J_ psTail) y N_
                        pure (z, J_ $ isoVar (tNet . onlyT) (tOnly . netT) s')
                    LS _ -> \case
                      J_ ss -> lenSs // do
                        (y, s' ) <- second fromJ_
                                <$> runLearnStoch      l  g (J_ psHead) x (J_ (ss ^^. netHead))
                        let ssTail = isoVar tNet netT $ ss ^^. netTail
                        (z, ss') <- second fromJ_
                                <$> runChainLearnStoch ls g (J_ psTail) y (J_ ssTail)
                        pure (z, J_ $ isoVar2 NET unNet s' $ isoVar netT tNet ss')

-- | Appending 'Chain'
(~++)
    :: forall ls ms ps qs ss ts a b c. ()
    => Chain ls ps ss a b
    -> Chain ms qs ts b c
    -> Chain (ls ++ ms) (ps ++ qs) (ss ++ ts) a c
(~++) = \case
    CNil     -> id
    (l :: l) :~> (ls :: Chain ls' ps' ss' a' b) ->
      case assocMaybAppend @(LParamMaybe l) @ps' @qs known of
        Refl -> case assocMaybAppend @(LStateMaybe l) @ss' @ts known of
          Refl -> \ms -> (l :~> (ls ~++ ms))
            \\ appendLength (chainParamLength ls) (chainParamLength ms)
            \\ appendLength (chainStateLength ls) (chainStateLength ms)

chainParamLength
    :: Chain ls ps ss a b
    -> Length ps
chainParamLength = \case
    CNil -> LZ
    (_ :: l) :~> ls -> case knownMayb @(LParamMaybe l) of
      N_   -> chainParamLength ls
      J_ _ -> LS $ chainParamLength ls

chainStateLength
    :: Chain ls ps ss a b
    -> Length ss
chainStateLength = \case
    CNil -> LZ
    (_ :: l) :~> ls -> case knownMayb @(LStateMaybe l) of
      N_   -> chainStateLength ls
      J_ _ -> LS $ chainStateLength ls


appendLength
    :: forall as bs. ()
    => Length as
    -> Length bs
    -> Length (as ++ bs)
appendLength LZ     = id
appendLength (LS l) = LS . appendLength l

assocMaybAppend
    :: forall a bs cs. ()
    => Mayb P a
    -> (MaybeToList a ++ (bs ++ cs)) :~: ((MaybeToList a ++ bs) ++ cs)
assocMaybAppend = \case
    N_   -> Refl
    J_ _ -> Refl

-- | Data type representing trainable models.
--
-- Useful for performant composition, but you lose the ability to decompose
-- parts.
data LearnFunc :: Maybe Type -> Maybe Type -> Type -> Type -> Type where
    LF :: { _lfInitParam :: forall m. PrimMonad m => MWC.Gen (PrimState m) -> Mayb m p
          , _lfInitState :: forall m. PrimMonad m => MWC.Gen (PrimState m) -> Mayb m s
          , _lfRunLearn
               :: forall q. Reifies q W
               => Mayb (BVar q) p
               -> BVar q a
               -> Mayb (BVar q) s
               -> (BVar q b, Mayb (BVar q) s)
          , _lfRunLearnStoch
               :: forall m q. (PrimMonad m, Reifies q W)
               => MWC.Gen (PrimState m)
               -> Mayb (BVar q) p
               -> BVar q a
               -> Mayb (BVar q) s
               -> m (BVar q b, Mayb (BVar q) s)
          }
       -> LearnFunc p s a b

learnFunc
    :: Learn a b l
    => l
    -> LearnFunc (LParamMaybe l) (LStateMaybe l) a b
learnFunc l = LF { _lfInitParam     = initParam l
                 , _lfInitState     = initState l
                 , _lfRunLearn      = runLearn l
                 , _lfRunLearnStoch = runLearnStoch l
                 }

instance Learn a b (LearnFunc p s a b) where
    type LParamMaybe (LearnFunc p s a b) = p
    type LStateMaybe (LearnFunc p s a b) = s

    initParam     = _lfInitParam
    initState     = _lfInitState
    runLearn      = _lfRunLearn
    runLearnStoch = _lfRunLearnStoch

instance (MaybeC Num p, MaybeC Num s, KnownMayb p, KnownMayb s) => Category (LearnFunc p s) where
    id = LF { _lfInitParam     = \_ -> map1 (pure 0 \\) $ maybeWit @_ @Num @p
            , _lfInitState     = \_ -> map1 (pure 0 \\) $ maybeWit @_ @Num @s
            , _lfRunLearn      = \_ -> (,)
            , _lfRunLearnStoch = \_ _ x -> pure . (x,)
            }
    f . g = LF { _lfInitParam = \gen -> zipMayb3 (liftA2 (+) \\)
                      (maybeWit @_ @Num @p)
                      (_lfInitParam f gen)
                      (_lfInitParam g gen)
               , _lfInitState = \gen -> zipMayb3 (liftA2 (+) \\)
                      (maybeWit @_ @Num @s)
                      (_lfInitState f gen)
                      (_lfInitState g gen)
               , _lfRunLearn  = \p x s0 ->
                    let (y, s1) = _lfRunLearn g p x s0
                    in  _lfRunLearn f p y s1
               , _lfRunLearnStoch = \gen p x s0 -> do
                    (y, s1) <- _lfRunLearnStoch g gen p x s0
                    _lfRunLearnStoch f gen p y s1
               }

-- | Compose two 'LearnFunc' on lists.
(.~)
    :: forall ps qs ss ts a b c.
     ( ListC (Num List.<$> ps)
     , ListC (Num List.<$> qs)
     , ListC (Num List.<$> ss)
     , ListC (Num List.<$> ts)
     , ListC (Num List.<$> (ss ++ ts))
     , Known Length ps
     , Known Length qs
     , Known Length ss
     , Known Length ts
     )
    => LearnFunc ('Just (T ps        )) ('Just (T ss         )) b c
    -> LearnFunc ('Just (T qs        )) ('Just (T ts         )) a b
    -> LearnFunc ('Just (T (ps ++ qs))) ('Just (T (ss ++ ts ))) a c
f .~ g = LF { _lfInitParam = \gen -> J_ $ tAppend <$> fromJ_ (_lfInitParam f gen)
                                                  <*> fromJ_ (_lfInitParam g gen)
            , _lfInitState = \gen -> J_ $ tAppend <$> fromJ_ (_lfInitState f gen)
                                                  <*> fromJ_ (_lfInitState g gen)

            , _lfRunLearn  = \(J_ psqs) x (J_ ssts) -> appendLength @ss @ts known known //
                let (y, J_ ts) = _lfRunLearn g (J_ (psqs ^^. tDrop @ps @qs known))
                                               x
                                               (J_ (ssts ^^. tDrop @ss @ts known))
                    (z, J_ ss) = _lfRunLearn f (J_ (psqs ^^. tTake @ps @qs known))
                                               y
                                               (J_ (ssts ^^. tTake @ss @ts known))
                in  (z, J_ $ isoVar2 (tAppend @ss @ts) (tSplit @ss @ts known)
                                     ss ts
                    )
            , _lfRunLearnStoch = \gen (J_ psqs) x (J_ ssts) -> appendLength @ss @ts known known // do
                (y, ts) <- second fromJ_
                       <$> _lfRunLearnStoch g gen (J_ (psqs ^^. tDrop @ps @qs known))
                                                  x
                                                  (J_ (ssts ^^. tDrop @ss @ts known))
                (z, ss) <- second fromJ_
                       <$> _lfRunLearnStoch f gen (J_ (psqs ^^. tTake @ps @qs known))
                                                   y
                                                   (J_ (ssts ^^. tTake @ss @ts known))
                pure  (z, J_ $ isoVar2 (tAppend @ss @ts) (tSplit @ss @ts known)
                                       ss ts
                      )
            }

-- | Identity of '.~'
nilLF :: LearnFunc ('Just (T '[])) ('Just (T '[])) a a
nilLF = id

-- | 'LearnFunc' with singleton lists; meant to be used with '.~'
onlyLF
    :: forall p s a b. (KnownMayb p, MaybeC Num p, KnownMayb s, MaybeC Num s)
    => LearnFunc p s a b
    -> LearnFunc ('Just (T (MaybeToList p))) ('Just (T (MaybeToList s))) a b
onlyLF f = LF
    { _lfInitParam = J_
                   . fmap prodT
                   . traverse1 (fmap I)
                   . maybToList
                   . _lfInitParam f
    , _lfInitState = J_
                   . fmap prodT
                   . traverse1 (fmap I)
                   . maybToList
                   . _lfInitState f
    , _lfRunLearn = \(J_ ps) x ssM@(J_ ss) -> case knownMayb @p of
        N_ -> case knownMayb @s of
          N_ -> (second . const) ssM
              $ _lfRunLearn f N_ x N_
          J_ _ -> second (J_ . isoVar onlyT tOnly . fromJ_)
                $ _lfRunLearn f N_ x (J_ (isoVar tOnly onlyT ss))
        J_ _ ->
          let p = isoVar tOnly onlyT ps
          in  case knownMayb @s of
                N_ -> (second . const) ssM
                    $ _lfRunLearn f (J_ p) x N_
                J_ _ -> second (J_ . isoVar onlyT tOnly . fromJ_)
                      $ _lfRunLearn f (J_ p) x (J_ (isoVar tOnly onlyT ss))
    , _lfRunLearnStoch = \g (J_ ps) x ssM@(J_ ss) -> case knownMayb @p of
        N_ -> case knownMayb @s of
          N_ -> (fmap . second . const) ssM
              $ _lfRunLearnStoch f g N_ x N_
          J_ _ -> (fmap . second) (J_ . isoVar onlyT tOnly . fromJ_)
                $ _lfRunLearnStoch f g N_ x (J_ (isoVar tOnly onlyT ss))
        J_ _ ->
          let p = isoVar tOnly onlyT ps
          in  case knownMayb @s of
                N_ -> (fmap . second . const) ssM
                    $ _lfRunLearnStoch f g (J_ p) x N_
                J_ _ -> (fmap . second) (J_ . isoVar onlyT tOnly . fromJ_)
                      $ _lfRunLearnStoch f g (J_ p) x (J_ (isoVar tOnly onlyT ss))
    }

-- | Compose two layers sequentially
data (:.~) :: Type -> Type -> Type where
    (:.~) :: l -> m -> l :.~ m

instance (Learn a b l, Learn b c m) => Learn a c (l :.~ m) where
    type LParamMaybe (l :.~ m) = TupMaybe (LParamMaybe l) (LParamMaybe m)
    type LStateMaybe (l :.~ m) = TupMaybe (LStateMaybe l) (LStateMaybe m)

    initParam = undefined
    initState = undefined

        -- elimTupMaybe (knownMayb @(LParamMaybe l))
        --              (knownMayb @(LStateMaybe l))
        --              ((, N_) . runLearnStateless l N_ $ x)
        --              ((second . const) N_ . runLearn l N_ x . J_)
        --              ((, N_) . flip (runLearnStateless l) x . J_)
        --              (\ps -> (second . const) N_
        --                    . runLearn l (J_ (ps ^^. t2_1)) x
        --                    $ J_ (ps ^^. t2_2)
        --              )
        --              t

