{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE PolyKinds                  #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeInType                 #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE UndecidableInstances       #-}

module Numeric.Backprop.Internal
 ( Op(..), composeOp, op1, op1', opN, opN'
 , Summer(..), summers, summers'
 , Unity(..), unities, unities'
 , BPState(..), bpsSources
 , BP(..)
 , BPInpRef(..)
 -- , BPComp(..)
 , BPNode(..), bpnOut, bpnRes, bpnGradFunc, bpnGradCache, bpnSummer
 , BPPipe(..), bppOut, bppRes, bppGradFunc, bppGradCache
 , BPRef(..)
 , ForwardRefs(..), _FRInternal
 ) where

import           Control.Monad.Reader
import           Control.Monad.ST
import           Control.Monad.State
import           Data.Bifunctor
import           Data.Kind
import           Data.List                   (foldl')
import           Data.Reflection             (Reifies)
import           Data.STRef
import           Data.Type.Combinator
import           Data.Type.Conjunction
import           Data.Type.Index
import           Data.Type.Length
import           Data.Type.Nat
import           Data.Type.Product
import           Data.Type.Util
import           Data.Type.Vector
import           Lens.Micro
import           Lens.Micro.TH
import           Numeric.AD                  (AD, grad', diff')
import           Numeric.AD.Internal.Reverse (Reverse, Tape)
import           Numeric.AD.Mode.Forward     (Forward)
import           Type.Class.Higher
import           Type.Class.Known
import           Type.Family.Nat

-- instead of Tuple as, Prod Diff as, where Diff can be a value, or zero,
-- or one?
newtype Op as a = Op { runOp' :: Tuple as -> (a, Maybe a -> Tuple as) }

newtype OpCont as a = OC { runOpCont :: Maybe a -> Tuple as }

composeOp :: Prod Summer as -> Prod (Op as) bs -> Op bs c -> Op as c
composeOp ss os o = Op $ \xs ->
    let (ys, conts) = unzipP
                    . map1 ((\(x, c) -> I x :&: OC c) . flip runOp' xs)
                    $ os
        (z, gFz) = runOp' o ys
    in  (z, map1 (\(s :&: gs) -> I $ runSummer s gs)
          . zipP ss
          . foldr (\x -> map1 (uncurryFan (\(I x) -> (x:))) . zipP x) (map1 (const []) ss)
          . toList (\(oc :&: I g) -> runOpCont oc (Just g))
          . zipP conts . gFz
        )

op1'
    :: (a -> (b, Maybe b -> a))
    -> Op '[a] b
op1' f = Op $ \case
    I x :< Ø ->
      let (y, dx) = f x
      in  (y, only_ . dx)

op1 :: Num a
    => (forall s. AD s (Forward a) -> AD s (Forward a))
    -> Op '[a] a
op1 f = op1' $ \x ->
    let (z, dx) = diff' f x
    in  (z, maybe dx (* dx))

opN' :: (Known Nat n)
     => (Vec n a -> (b, Maybe b -> Vec n a))
     -> Op (Replicate n a) b
opN' f = Op $ (second . fmap) vecToProd
            . f
            . prodToVec' known

opN :: (Num a, Known Nat n)
    => (forall s. Reifies s Tape => Vec n (Reverse s a) -> Reverse s a)
    -> Op (Replicate n a) a
opN f = opN' $ \xs ->
    let (y, dxs) = grad' f xs
    in  (y, maybe dxs (\q -> (q *) <$> dxs))

instance (Known Length as, Every Num as, Num a) => Num (Op as a) where
    o1 + o2   = composeOp summers (o1 :< o2 :< Ø) (opN $ \(I x :* I y :* ØV) -> x + y   )
    o1 * o2   = composeOp summers (o1 :< o2 :< Ø) (opN $ \(I x :* I y :* ØV) -> x * y   )
    o1 - o2   = composeOp summers (o1 :< o2 :< Ø) (opN $ \(I x :* I y :* ØV) -> x - y   )
    negate o1 = composeOp summers (only o1)       (op1 negate)
    abs    o1 = composeOp summers (only o1)       (op1 abs   )
    signum o1 = composeOp summers (only o1)       (op1 signum)

newtype Summer a = Summer { runSummer :: [a] -> a }
newtype Unity  a = Unity  { getUnity  :: a        }
    deriving (Functor, Show, Ord, Eq, Num, Fractional, Floating, Integral, Real, Enum, RealFloat, RealFrac)

instance Num a => Known Summer a where
    type KnownC Summer a = Num a
    known = Summer sum

instance Num a => Known Unity a where
    type KnownC Unity a = Num a
    known = Unity 1

summers
    :: (Every Num as, Known Length as)
    => Prod Summer as
summers = summers' known

summers'
    :: Every Num as
    => Length as
    -> Prod Summer as
summers' l = withEvery' @Num l known

unities
    :: (Every Num as, Known Length as)
    => Prod Unity as
unities = unities' known

unities'
    :: Every Num as
    => Length as
    -> Prod Unity as
unities' l = withEvery' @Num l known

data ForwardRefs s rs a = FRInternal ![BPInpRef s rs a]
                        | FRExternal a
                        | FRTerminal

data BPState :: Type -> [Type] -> Type where
    BPS :: { _bpsSources :: !(Prod (ForwardRefs s rs) rs)
           }
        -> BPState s rs

newtype BP s rs b = BP { bpST :: ReaderT (Tuple rs) (StateT (BPState s rs) (ST s)) b }
      deriving ( Functor
               , Applicative
               , Monad
               )

data BPRef :: Type -> [Type] -> Type -> Type where
    BPRNode  :: !(Index bs a)
             -> !(STRef s (BPNode s rs as bs))
             -> BPRef s rs a
    BPRInp   :: !(Index rs a)
             -> BPRef s rs a
    BPRConst :: !a
             -> BPRef s rs a
    BPROp    :: !(Prod (BPRef s rs) as)
             -> !(Op as a)
             -> BPRef s rs a

data BPInpRef :: Type -> [Type] -> Type -> Type where
    IRNode :: !(Index bs a)
           -> !(STRef s (BPNode s rs bs cs))
           -> BPInpRef s rs a
    IRPipe :: !(Index bs a)
           -> !(STRef s (BPPipe s rs bs cs))
           -> BPInpRef s rs a

-- data BPComp :: Type -> [Type] -> [Type] -> [Type] -> Type where
--     BPCNode :: !(BPNode s rs as bs)
--             -> BPComp s rs as bs
--     BPCPipe :: !(BPPipe s rs as bs)
--             -> BPComp s rs as bs

data BPNode :: Type -> [Type] -> [Type] -> [Type] -> Type where
    BPN :: { _bpnOut       :: !(Prod (ForwardRefs s rs) bs)
           , _bpnRes       :: !(Tuple bs)
           , _bpnGradFunc  :: !(Prod Maybe bs -> ST s (Tuple as))
           , _bpnGradCache :: !(Maybe (Tuple as))  -- nothing if is the "final output"
           , _bpnSummer    :: !(Prod Summer bs)
           }
        -> BPNode s rs as bs
-- data ForwardRefs s rs a = FRInternal ![BPInpRef s rs a]

data BPPipe :: Type -> [Type] -> [Type] -> [Type] -> Type where
    BPP :: { _bppOut       :: !(Prod (BPInpRef s rs) bs)
           , _bppRes       :: !(Tuple bs)
           , _bppGradFunc  :: !(Tuple bs -> Tuple as)
           , _bppGradCache :: !(Maybe (Tuple as))
           }
        -> BPPipe s rs as bs

makeLenses ''BPState
makeLenses ''BPNode
makeLenses ''BPPipe

_FRInternal
    :: Traversal (ForwardRefs s as a) (ForwardRefs t bs a)
                 [BPInpRef s as a]    [BPInpRef t bs a]
_FRInternal f = \case
    FRInternal xs -> FRInternal <$> f xs
    FRExternal x  -> pure (FRExternal x)
    FRTerminal    -> pure FRTerminal

