{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DefaultSignatures          #-}
{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveFoldable             #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DeriveTraversable          #-}
{-# LANGUAGE EmptyCase                  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE UndecidableInstances       #-}

-- |
-- Module      : Numeric.Backprop.Class
-- Copyright   : (c) Justin Le 2018
-- License     : BSD3
--
-- Maintainer  : justin@jle.im
-- Stability   : experimental
-- Portability : non-portable
--
-- Provides the 'Backprop' typeclass, a class for values that can be used
-- for backpropagation.
--
-- This class replaces the old (version 0.1) API relying on 'Num'.
--
-- @since 0.2.0.0

module Numeric.Backprop.Class (
  -- * Backpropagatable types
    Backprop(..)
  -- * Derived methods
  , zeroNum, addNum, oneNum
  , zeroVec, addVec, oneVec, zeroVecNum, oneVecNum
  , zeroFunctor, addIsList, addAsList, oneFunctor
  , genericZero, genericAdd, genericOne
  -- * Newtype
  , ABP(..), NumBP(..), NumVec(..)
  -- * Generics
  , GZero, GAdd, GOne
  ) where

import           Control.Applicative
import           Control.DeepSeq
import           Control.Monad
import           Data.Coerce
import           Data.Complex
import           Data.Data
import           Data.Foldable hiding     (toList)
import           Data.Functor.Compose
import           Data.Functor.Identity
import           Data.List.NonEmpty       (NonEmpty(..))
import           Data.Monoid
import           Data.Ratio
import           Data.Void
import           Data.Word
import           GHC.Exts
import           GHC.Generics
import           Numeric.Natural
import qualified Control.Arrow            as Arr
import qualified Data.Functor.Product     as DFP
import qualified Data.IntMap              as IM
import qualified Data.Map                 as M
import qualified Data.Semigroup           as SG
import qualified Data.Sequence            as Seq
import qualified Data.Vector              as V
import qualified Data.Vector.Generic      as VG
import qualified Data.Vector.Primitive    as VP
import qualified Data.Vector.Storable     as VS
import qualified Data.Vector.Unboxed      as VU

-- | Class of values that can be backpropagated in general.
--
-- For instances of 'Num', these methods can be given by 'zeroNum',
-- 'addNum', and 'oneNum'.  There are also generic options given in
-- "Numeric.Backprop.Class" for functors, 'IsList' instances, and 'Generic'
-- instances.
--
-- @
-- instance 'Backprop' 'Double' where
--     'zero' = 'zeroNum'
--     'add' = 'addNum'
--     'one' = 'oneNum'
-- @
--
-- If you leave the body of an instance declaration blank, GHC Generics
-- will be used to derive instances if the type has a single constructor
-- and each field is an instance of 'Backprop'.
--
-- To ensure that backpropagation works in a sound way, should obey the
-- laws:
--
-- [/identity/]
--
--   * @'add' x ('zero' y) = x@
--
--   * @'add' ('zero' x) y = y@
--
-- Also implies preservation of information, making @'zipWith' ('+')@ an
-- illegal implementation for lists and vectors.
--
-- This is only expected to be true up to potential "extra zeroes" in @x@
-- and @y@ in the result.
--
-- [/commutativity/]
--
--   * @'add' x y = 'add' y x@
--
-- [/associativity/]
--
--   * @'add' x ('add' y z) = 'add' ('add' x y) z@
--
-- [/idempotence/]
--
--   * @'zero' '.' 'zero' = 'zero'@
--
--   * @'one' '.' 'one' = 'one'@
--
-- [/unital/]
--
--   * @'one' = 'gradBP' 'id'@
--
-- Note that not all values in the backpropagation process needs all of
-- these methods: Only the "final result" needs 'one', for example.  These
-- are all grouped under one typeclass for convenience in defining
-- instances, and also to talk about sensible laws.  For fine-grained
-- control, use the "explicit" versions of library functions (for example,
-- in "Numeric.Backprop.Explicit") instead of 'Backprop' based ones.
--
-- This typeclass replaces the reliance on 'Num' of the previous API
-- (v0.1).  'Num' is strictly more powerful than 'Backprop', and is
-- a stronger constraint on types than is necessary for proper
-- backpropagating.  In particular, 'fromInteger' is a problem for many
-- types, preventing useful backpropagation for lists, variable-length
-- vectors (like "Data.Vector") and variable-size matrices from linear
-- algebra libraries like /hmatrix/ and /accelerate/.
--
-- @since 0.2.0.0
class Backprop a where
    -- | "Zero out" all components of a value.  For scalar values, this
    -- should just be @'const' 0@.  For vectors and matrices, this should
    -- set all components to zero, the additive identity.
    --
    -- Should be idempotent:
    --
    --   * @'zero' '.' 'zero' = 'zero'@
    --
    -- Should be as /lazy/ as possible.  This behavior is observed for
    -- all instances provided by this library.
    --
    -- See 'zeroNum' for a pre-built definition for instances of 'Num' and
    -- 'zeroFunctor' for a definition for instances of 'Functor'.  If left
    -- blank, will automatically be 'genericZero', a pre-built definition
    -- for instances of 'GHC.Generic' whose fields are all themselves
    -- instances of 'Backprop'.
    zero :: a -> a
    -- | Add together two values of a type.  To combine contributions of
    -- gradients, so should be information-preserving:
    --
    --   * @'add' x ('zero' y) = x@
    --
    --   * @'add' ('zero' x) y = y@
    --
    -- Should be as /strict/ as possible.  This behavior is observed for
    -- all instances provided by this library.
    --
    -- See 'addNum' for a pre-built definition for instances of 'Num' and
    -- 'addIsList' for a definition for instances of 'IsList'.  If left
    -- blank, will automatically be 'genericAdd', a pre-built definition
    -- for instances of 'GHC.Generic' with one constructor whose fields are
    -- all themselves instances of 'Backprop'.
    add  :: a -> a -> a
    -- | "One" all components of a value.  For scalar values, this should
    -- just be @'const' 1@.  For vectors and matrices, this should set all
    -- components to one, the multiplicative identity.
    --
    -- As the library uses it, the most important law is:
    --
    --   * @'one' = 'gradBP' 'id'@
    --
    -- That is, @'one' x@ is the gradient of the identity function with
    -- respect to its input.
    --
    -- Ideally should be idempotent:
    --
    --   * @'one' '.' 'one' = 'one'@
    --
    -- Should be as /lazy/ as possible.  This behavior is observed for
    -- all instances provided by this library.
    --
    -- See 'oneNum' for a pre-built definition for instances of 'Num' and
    -- 'oneFunctor' for a definition for instances of 'Functor'.  If left
    -- blank, will automatically be 'genericOne', a pre-built definition
    -- for instances of 'GHC.Generic' whose fields are all themselves
    -- instances of 'Backprop'.
    one  :: a -> a

    default zero :: (Generic a, GZero (Rep a)) => a -> a
    zero = genericZero
    {-# INLINE zero #-}
    default add :: (Generic a, GAdd (Rep a)) => a -> a -> a
    add = genericAdd
    {-# INLINE add #-}
    default one :: (Generic a, GOne (Rep a)) => a -> a
    one = genericOne
    {-# INLINE one #-}

-- | 'zero' using GHC Generics; works if all fields are instances of
-- 'Backprop'.
genericZero :: (Generic a, GZero (Rep a)) => a -> a
genericZero = to . gzero . from
{-# INLINE genericZero #-}

-- | 'add' using GHC Generics; works if all fields are instances of
-- 'Backprop', but only for values with single constructors.
genericAdd :: (Generic a, GAdd (Rep a)) => a -> a -> a
genericAdd x y = to $ gadd (from x) (from y)
{-# INLINE genericAdd #-}

-- | 'one' using GHC Generics; works if all fields are instaces of
-- 'Backprop'.
genericOne :: (Generic a, GOne (Rep a)) => a -> a
genericOne = to . gone . from
{-# INLINE genericOne #-}

-- | 'zero' for instances of 'Num'.
--
-- Is lazy in its argument.
zeroNum :: Num a => a -> a
zeroNum _ = 0
{-# INLINE zeroNum #-}

-- | 'add' for instances of 'Num'.
addNum :: Num a => a -> a -> a
addNum = (+)
{-# INLINE addNum #-}

-- | 'one' for instances of 'Num'.
--
-- Is lazy in its argument.
oneNum :: Num a => a -> a
oneNum _ = 1
{-# INLINE oneNum #-}

-- | 'zero' for instances of 'VG.Vector'.
zeroVec :: (VG.Vector v a, Backprop a) => v a -> v a
zeroVec = VG.map zero
{-# INLINE zeroVec #-}

-- | 'add' for instances of 'VG.Vector'.  Automatically pads the end of the
-- shorter vector with zeroes.
addVec :: (VG.Vector v a, Backprop a) => v a -> v a -> v a
addVec x y = case compare lX lY of
    LT -> let (y1,y2) = VG.splitAt (lY - lX) y
          in  VG.zipWith add x y1 VG.++ y2
    EQ -> VG.zipWith add x y
    GT -> let (x1,x2) = VG.splitAt (lX - lY) x
          in  VG.zipWith add x1 y VG.++ x2
  where
    lX = VG.length x
    lY = VG.length y

-- | 'one' for instances of 'VG.Vector'.
oneVec :: (VG.Vector v a, Backprop a) => v a -> v a
oneVec = VG.map one
{-# INLINE oneVec #-}

-- | 'zero' for instances of 'VG.Vector' when the contained type is an
-- instance of 'Num'.  Is potentially more performant than 'zeroVec' when
-- the vectors are larger.
--
-- See 'NumVec' for a 'Backprop' instance for 'VG.Vector' instances that
-- uses this for 'zero'.
--
-- @since 0.2.4.0
zeroVecNum :: (VG.Vector v a, Num a) => v a -> v a
zeroVecNum = flip VG.replicate 0 . VG.length
{-# INLINE zeroVecNum #-}

-- | 'one' for instances of 'VG.Vector' when the contained type is an
-- instance of 'Num'.  Is potentially more performant than 'oneVec' when
-- the vectors are larger.
--
-- See 'NumVec' for a 'Backprop' instance for 'VG.Vector' instances that
-- uses this for 'one'.
--
-- @since 0.2.4.0
oneVecNum :: (VG.Vector v a, Num a) => v a -> v a
oneVecNum = flip VG.replicate 1 . VG.length
{-# INLINE oneVecNum #-}

-- | 'zero' for 'Functor' instances.
zeroFunctor :: (Functor f, Backprop a) => f a -> f a
zeroFunctor = fmap zero
{-# INLINE zeroFunctor #-}

-- | 'add' for instances of 'IsList'.  Automatically pads the end of the
-- "shorter" value with zeroes.
addIsList :: (IsList a, Backprop (Item a)) => a -> a -> a
addIsList = addAsList toList fromList
{-# INLINE addIsList #-}

-- | 'add' for types that are isomorphic to a list.
-- Automatically pads the end of the "shorter" value with zeroes.
addAsList
    :: Backprop b
    => (a -> [b])       -- ^ convert to list (should form isomorphism)
    -> ([b] -> a)       -- ^ convert from list (should form isomorphism)
    -> a
    -> a
    -> a
addAsList f g x y = g $ go (f x) (f y)
  where
    go = \case
      [] -> id
      o@(x':xs) -> \case
        []    -> o
        y':ys -> add x' y' : go xs ys

-- | 'one' for instances of 'Functor'.
oneFunctor :: (Functor f, Backprop a) => f a -> f a
oneFunctor = fmap one
{-# INLINE oneFunctor #-}

-- | A newtype wrapper over an instance of 'Num' that gives a free
-- 'Backprop' instance.
--
-- Useful for things like /DerivingVia/, or for avoiding orphan instances.
--
-- @since 0.2.1.0
newtype NumBP a = NumBP { runNumBP :: a }
  deriving (Show, Read, Eq, Ord, Typeable, Data, Generic, Functor, Foldable, Traversable, Num, Fractional, Floating)

instance NFData a => NFData (NumBP a)

instance Applicative NumBP where
    pure    = NumBP
    {-# INLINE pure #-}
    f <*> x = NumBP $ (runNumBP f) (runNumBP x)
    {-# INLINE (<*>) #-}

instance Monad NumBP where
    return = NumBP
    {-# INLINE return #-}
    x >>= f = f (runNumBP x)
    {-# INLINE (>>=) #-}

instance Num a => Backprop (NumBP a) where
    zero = coerce (zeroNum :: a -> a)
    {-# INLINE zero #-}
    add = coerce (addNum :: a -> a -> a)
    {-# INLINE add #-}
    one = coerce (oneNum :: a -> a)
    {-# INLINE one #-}

-- | Newtype wrapper around a @v a@ for @'VG.Vector' v a@, that gives
-- a more efficient 'Backprop' instance for /long/ vectors when @a@ is an
-- instance of 'Num'.  The normal 'Backprop' instance for vectors will map
-- 'zero' or 'one' over all items; this instance will completely ignore the
-- contents of the original vector and instead produce a new vector of the
-- same length, with all @0@ or @1@ using the 'Num' instance of @a@
-- (essentially using 'zeroVecNum' and 'oneVecNum' instead of 'zeroVec' and
-- 'oneVec').
--
-- 'add' is essentially the same as normal, but using '+' instead of the
-- type's 'add'.
--
-- @since 0.2.4.0
newtype NumVec v a = NumVec { runNumVec :: v a }
  deriving (Show, Read, Eq, Ord, Typeable, Data, Generic, Functor, Applicative, Monad, Alternative, MonadPlus, Foldable, Traversable)

instance NFData (v a) => NFData (NumVec v a)

instance (VG.Vector v a, Num a) => Backprop (NumVec v a) where
    zero = coerce $ zeroVecNum @v @a
    add (NumVec x) (NumVec y) = NumVec $ case compare lX lY of
        LT -> let (y1,y2) = VG.splitAt (lY - lX) y
              in  VG.zipWith (+) x y1 VG.++ y2
        EQ -> VG.zipWith (+) x y
        GT -> let (x1,x2) = VG.splitAt (lX - lY) x
              in  VG.zipWith (+) x1 y VG.++ x2
      where
        lX = VG.length x
        lY = VG.length y
    one = coerce $ oneVecNum @v @a

-- | A newtype wrapper over an @f a@ for @'Applicative' f@ that gives
-- a free 'Backprop' instance (as well as 'Num' etc. instances).
--
-- Useful for performing backpropagation over functions that require some
-- monadic context (like 'IO') to perform.
--
-- @since 0.2.1.0
newtype ABP f a = ABP { runABP :: f a }
  deriving (Show, Read, Eq, Ord, Typeable, Data, Generic, Functor, Applicative, Monad, Alternative, MonadPlus, Foldable, Traversable)

instance NFData (f a) => NFData (ABP f a)

instance (Applicative f, Backprop a) => Backprop (ABP f a) where
    zero = fmap zero
    {-# INLINE zero #-}
    add  = liftA2 add
    {-# INLINE add #-}
    one  = fmap one
    {-# INLINE one #-}

instance (Applicative f, Num a) => Num (ABP f a) where
    (+) = liftA2 (+)
    {-# INLINE (+) #-}
    (-) = liftA2 (-)
    {-# INLINE (-) #-}
    (*) = liftA2 (*)
    {-# INLINE (*) #-}
    negate = fmap negate
    {-# INLINE negate #-}
    abs = fmap abs
    {-# INLINE abs #-}
    signum = fmap signum
    {-# INLINE signum #-}
    fromInteger = pure . fromInteger
    {-# INLINE fromInteger #-}

instance (Applicative f, Fractional a) => Fractional (ABP f a) where
    (/) = liftA2 (/)
    {-# INLINE (/) #-}
    recip = fmap recip
    {-# INLINE recip #-}
    fromRational = pure . fromRational
    {-# INLINE fromRational #-}

instance (Applicative f, Floating a) => Floating (ABP f a) where
    pi  = pure pi
    {-# INLINE pi #-}
    exp = fmap exp
    {-# INLINE exp #-}
    log = fmap log
    {-# INLINE log #-}
    sqrt = fmap sqrt
    {-# INLINE sqrt #-}
    (**) = liftA2 (**)
    {-# INLINE (**) #-}
    logBase = liftA2 logBase
    {-# INLINE logBase #-}
    sin = fmap sin
    {-# INLINE sin #-}
    cos = fmap cos
    {-# INLINE cos #-}
    tan = fmap tan
    {-# INLINE tan #-}
    asin = fmap asin
    {-# INLINE asin #-}
    acos = fmap acos
    {-# INLINE acos #-}
    atan = fmap atan
    {-# INLINE atan #-}
    sinh = fmap sinh
    {-# INLINE sinh #-}
    cosh = fmap cosh
    {-# INLINE cosh #-}
    tanh = fmap tanh
    {-# INLINE tanh #-}
    asinh = fmap asinh
    {-# INLINE asinh #-}
    acosh = fmap acosh
    {-# INLINE acosh #-}
    atanh = fmap atanh
    {-# INLINE atanh #-}


-- | Helper class for automatically deriving 'zero' using GHC Generics.
class GZero f where
    gzero :: f t -> f t

instance Backprop a => GZero (K1 i a) where
    gzero (K1 x) = K1 (zero x)
    {-# INLINE gzero #-}

instance (GZero f, GZero g) => GZero (f :*: g) where
    gzero (x :*: y) = gzero x :*: gzero y
    {-# INLINE gzero #-}

instance (GZero f, GZero g) => GZero (f :+: g) where
    gzero (L1 x) = L1 (gzero x)
    gzero (R1 x) = R1 (gzero x)
    {-# INLINE gzero #-}

instance GZero V1 where
    gzero = \case {}
    {-# INLINE gzero #-}

instance GZero U1 where
    gzero _ = U1
    {-# INLINE gzero #-}

instance GZero f => GZero (M1 i c f) where
    gzero (M1 x) = M1 (gzero x)
    {-# INLINE gzero #-}

instance GZero f => GZero (f :.: g) where
    gzero (Comp1 x) = Comp1 (gzero x)
    {-# INLINE gzero #-}


-- | Helper class for automatically deriving 'add' using GHC Generics.
class GAdd f where
    gadd :: f t -> f t -> f t

instance Backprop a => GAdd (K1 i a) where
    gadd (K1 x) (K1 y) = K1 (add x y)
    {-# INLINE gadd #-}

instance (GAdd f, GAdd g) => GAdd (f :*: g) where
    gadd (x1 :*: y1) (x2 :*: y2) = x3 :*: y3
      where
        !x3 = gadd x1 x2
        !y3 = gadd y1 y2
    {-# INLINE gadd #-}

instance GAdd V1 where
    gadd = \case {}
    {-# INLINE gadd #-}

instance GAdd U1 where
    gadd _ _ = U1
    {-# INLINE gadd #-}

instance GAdd f => GAdd (M1 i c f) where
    gadd (M1 x) (M1 y) = M1 (gadd x y)
    {-# INLINE gadd #-}

instance GAdd f => GAdd (f :.: g) where
    gadd (Comp1 x) (Comp1 y) = Comp1 (gadd x y)
    {-# INLINE gadd #-}


-- | Helper class for automatically deriving 'one' using GHC Generics.
class GOne f where
    gone :: f t -> f t

instance Backprop a => GOne (K1 i a) where
    gone (K1 x) = K1 (one x)
    {-# INLINE gone #-}

instance (GOne f, GOne g) => GOne (f :*: g) where
    gone (x :*: y) = gone x :*: gone y
    {-# INLINE gone #-}

instance (GOne f, GOne g) => GOne (f :+: g) where
    gone (L1 x) = L1 (gone x)
    gone (R1 x) = R1 (gone x)
    {-# INLINE gone #-}

instance GOne V1 where
    gone = \case {}
    {-# INLINE gone #-}

instance GOne U1 where
    gone _ = U1
    {-# INLINE gone #-}

instance GOne f => GOne (M1 i c f) where
    gone (M1 x) = M1 (gone x)
    {-# INLINE gone #-}

instance GOne f => GOne (f :.: g) where
    gone (Comp1 x) = Comp1 (gone x)
    {-# INLINE gone #-}

instance Backprop Int where
    zero = zeroNum
    {-# INLINE zero #-}
    add  = addNum
    {-# INLINE add #-}
    one  = oneNum
    {-# INLINE one #-}

instance Backprop Integer where
    zero = zeroNum
    {-# INLINE zero #-}
    add  = addNum
    {-# INLINE add #-}
    one  = oneNum
    {-# INLINE one #-}

-- | @since 0.2.1.0
instance Backprop Natural where
    zero = zeroNum
    {-# INLINE zero #-}
    add  = addNum
    {-# INLINE add #-}
    one  = oneNum
    {-# INLINE one #-}

-- | @since 0.2.2.0
instance Backprop Word8 where
    zero = zeroNum
    {-# INLINE zero #-}
    add  = addNum
    {-# INLINE add #-}
    one  = oneNum
    {-# INLINE one #-}

-- | @since 0.2.2.0
instance Backprop Word where
    zero = zeroNum
    {-# INLINE zero #-}
    add  = addNum
    {-# INLINE add #-}
    one  = oneNum
    {-# INLINE one #-}

-- | @since 0.2.2.0
instance Backprop Word16 where
    zero = zeroNum
    {-# INLINE zero #-}
    add  = addNum
    {-# INLINE add #-}
    one  = oneNum
    {-# INLINE one #-}

-- | @since 0.2.2.0
instance Backprop Word32 where
    zero = zeroNum
    {-# INLINE zero #-}
    add  = addNum
    {-# INLINE add #-}
    one  = oneNum
    {-# INLINE one #-}

-- | @since 0.2.2.0
instance Backprop Word64 where
    zero = zeroNum
    {-# INLINE zero #-}
    add  = addNum
    {-# INLINE add #-}
    one  = oneNum
    {-# INLINE one #-}

instance Integral a => Backprop (Ratio a) where
    zero = zeroNum
    {-# INLINE zero #-}
    add  = addNum
    {-# INLINE add #-}
    one  = oneNum
    {-# INLINE one #-}

instance RealFloat a => Backprop (Complex a) where
    zero = zeroNum
    {-# INLINE zero #-}
    add  = addNum
    {-# INLINE add #-}
    one  = oneNum
    {-# INLINE one #-}

instance Backprop Float where
    zero = zeroNum
    {-# INLINE zero #-}
    add  = addNum
    {-# INLINE add #-}
    one  = oneNum
    {-# INLINE one #-}

instance Backprop Double where
    zero = zeroNum
    {-# INLINE zero #-}
    add  = addNum
    {-# INLINE add #-}
    one  = oneNum
    {-# INLINE one #-}

instance Backprop a => Backprop (V.Vector a) where
    zero = zeroVec
    {-# INLINE zero #-}
    add  = addVec
    {-# INLINE add #-}
    one  = oneVec
    {-# INLINE one #-}

instance (VU.Unbox a, Backprop a) => Backprop (VU.Vector a) where
    zero = zeroVec
    {-# INLINE zero #-}
    add  = addVec
    {-# INLINE add #-}
    one  = oneVec
    {-# INLINE one #-}

instance (VS.Storable a, Backprop a) => Backprop (VS.Vector a) where
    zero = zeroVec
    {-# INLINE zero #-}
    add  = addVec
    {-# INLINE add #-}
    one  = oneVec
    {-# INLINE one #-}

instance (VP.Prim a, Backprop a) => Backprop (VP.Vector a) where
    zero = zeroVec
    {-# INLINE zero #-}
    add  = addVec
    {-# INLINE add #-}
    one  = oneVec
    {-# INLINE one #-}

-- | 'add' assumes the shorter list has trailing zeroes, and the result has
-- the length of the longest input.
instance Backprop a => Backprop [a] where
    zero = zeroFunctor
    {-# INLINE zero #-}
    add  = addIsList
    {-# INLINE add #-}
    one  = oneFunctor
    {-# INLINE one #-}

-- | 'add' assumes the shorter list has trailing zeroes, and the result has
-- the length of the longest input.
instance Backprop a => Backprop (NonEmpty a) where
    zero = zeroFunctor
    {-# INLINE zero #-}
    add  = addIsList
    {-# INLINE add #-}
    one  = oneFunctor
    {-# INLINE one #-}

-- | 'add' assumes the shorter sequence has trailing zeroes, and the result
-- has the length of the longest input.
instance Backprop a => Backprop (Seq.Seq a) where
    zero = zeroFunctor
    {-# INLINE zero #-}
    add  = addIsList
    {-# INLINE add #-}
    one  = oneFunctor
    {-# INLINE one #-}

-- | 'Nothing' is treated the same as @'Just' 0@.  However, 'zero', 'add',
-- and 'one' preserve 'Nothing' if all inputs are also 'Nothing'.
instance Backprop a => Backprop (Maybe a) where
    zero = zeroFunctor
    {-# INLINE zero #-}
    add x y = asum [ add <$> x <*> y
                   , x
                   , y
                   ]
    {-# INLINE add #-}
    one  = oneFunctor
    {-# INLINE one #-}

-- | 'add' is strict, but 'zero' and 'one' are lazy in their arguments.
instance Backprop () where
    zero _ = ()
    add () () = ()
    one _ = ()

-- | 'add' is strict
instance (Backprop a, Backprop b) => Backprop (a, b) where
    zero (x, y) = (zero x, zero y)
    {-# INLINE zero #-}
    add (x1, y1) (x2, y2) = (x3, y3)
      where
        !x3 = add x1 x2
        !y3 = add y1 y2
    {-# INLINE add #-}
    one (x, y) = (one x, one y)
    {-# INLINE one #-}

-- | 'add' is strict
instance (Backprop a, Backprop b, Backprop c) => Backprop (a, b, c) where
    zero (x, y, z) = (zero x, zero y, zero z)
    {-# INLINE zero #-}
    add (x1, y1, z1) (x2, y2, z2) = (x3, y3, z3)
      where
        !x3 = add x1 x2
        !y3 = add y1 y2
        !z3 = add z1 z2
    {-# INLINE add #-}
    one (x, y, z) = (one x, one y, one z)
    {-# INLINE one #-}

-- | 'add' is strict
instance (Backprop a, Backprop b, Backprop c, Backprop d) => Backprop (a, b, c, d) where
    zero (x, y, z, w) = (zero x, zero y, zero z, zero w)
    {-# INLINE zero #-}
    add (x1, y1, z1, w1) (x2, y2, z2, w2) = (x3, y3, z3, w3)
      where
        !x3 = add x1 x2
        !y3 = add y1 y2
        !z3 = add z1 z2
        !w3 = add w1 w2
    {-# INLINE add #-}
    one (x, y, z, w) = (one x, one y, one z, one w)
    {-# INLINE one #-}

-- | 'add' is strict
instance (Backprop a, Backprop b, Backprop c, Backprop d, Backprop e) => Backprop (a, b, c, d, e) where
    zero (x, y, z, w, v) = (zero x, zero y, zero z, zero w, zero v)
    {-# INLINE zero #-}
    add (x1, y1, z1, w1, v1) (x2, y2, z2, w2, v2) = (x3, y3, z3, w3, v3)
      where
        !x3 = add x1 x2
        !y3 = add y1 y2
        !z3 = add z1 z2
        !w3 = add w1 w2
        !v3 = add v1 v2
    {-# INLINE add #-}
    one (x, y, z, w, v) = (one x, one y, one z, one w, one v)
    {-# INLINE one #-}

instance Backprop a => Backprop (Identity a) where
    zero (Identity x) = Identity (zero x)
    {-# INLINE zero #-}
    add (Identity x) (Identity y) = Identity (add x y)
    {-# INLINE add #-}
    one (Identity x) = Identity (one x)
    {-# INLINE one #-}

-- instance Backprop a => Backprop (I a) where
--     zero (I x) = I (zero x)
--     {-# INLINE zero #-}
--     add (I x) (I y) = I (add x y)
--     {-# INLINE add #-}
--     one (I x) = I (one x)
--     {-# INLINE one #-}

instance Backprop (Proxy a) where
    zero _ = Proxy
    {-# INLINE zero #-}
    add _ _ = Proxy
    {-# INLINE add #-}
    one _ = Proxy
    {-# INLINE one #-}

-- | @since 0.2.2.0
instance Backprop w => Backprop (Const w a) where
    zero (Const x) = Const (zero x)
    add (Const x) (Const y) = Const (add x y)
    one (Const x) = Const (one x)

instance Backprop Void where
    zero = \case {}
    {-# INLINE zero #-}
    add = \case {}
    {-# INLINE add #-}
    one = \case {}
    {-# INLINE one #-}

-- | 'zero' and 'one' replace all current values, and 'add' merges keys
-- from both maps, adding in the case of double-occurrences.
instance (Backprop a, Ord k) => Backprop (M.Map k a) where
    zero = zeroFunctor
    {-# INLINE zero #-}
    add  = M.unionWith add
    {-# INLINE add #-}
    one  = oneFunctor
    {-# INLINE one #-}

-- | 'zero' and 'one' replace all current values, and 'add' merges keys
-- from both maps, adding in the case of double-occurrences.
instance (Backprop a) => Backprop (IM.IntMap a) where
    zero = zeroFunctor
    {-# INLINE zero #-}
    add  = IM.unionWith add
    {-# INLINE add #-}
    one  = oneFunctor
    {-# INLINE one #-}

-- instance ListC (Backprop <$> (f <$> as)) => Backprop (Prod f as) where
--     zero = \case
--       Ø -> Ø
--       x :< xs -> zero x :< zero xs
--     {-# INLINE zero #-}
--     add = \case
--       Ø -> \case
--         Ø -> Ø
--       x :< xs -> \case
--         y :< ys -> add x y :< add xs ys
--     {-# INLINE add #-}
--     one = \case
--       Ø       -> Ø
--       x :< xs -> one x :< one xs
--     {-# INLINE one #-}

-- instance M.MaybeC (Backprop M.<$> (f M.<$> a)) => Backprop (Option f a) where
--     zero = \case
--       Nothing_ -> Nothing_
--       Just_ x  -> Just_ (zero x)
--     {-# INLINE zero #-}
--     add = \case
--       Nothing_ -> \case
--         Nothing_ -> Nothing_
--       Just_ x -> \case
--         Just_ y -> Just_ (add x y)
--     {-# INLINE add #-}
--     one = \case
--       Nothing_ -> Nothing_
--       Just_ x  -> Just_ (one x)
--     {-# INLINE one #-}

-- -- | @since 0.2.2.0
-- instance (Backprop (f a), Backprop (g a)) => Backprop ((f :&: g) a) where
--     zero (x :&: y) = zero x :&: zero y
--     {-# INLINE zero #-}
--     add (x1 :&: y1) (x2 :&: y2) = add x1 x2 :&: add y1 y2
--     {-# INLINE add #-}
--     one (x :&: y) = one x :&: one y
--     {-# INLINE one #-}

-- -- | @since 0.2.2.0
-- instance (Backprop (f a), Backprop (g b)) => Backprop ((f TC.:*: g) '(a, b)) where
--     zero (x TC.:*: y) = zero x TC.:*: zero y
--     {-# INLINE zero #-}
--     add (x1 TC.:*: y1) (x2 TC.:*: y2) = add x1 x2 TC.:*: add y1 y2
--     {-# INLINE add #-}
--     one (x TC.:*: y) = one x TC.:*: one y
--     {-# INLINE one #-}

-- -- | @since 0.2.2.0
-- instance Backprop (f (g h) a) => Backprop (TC.Comp1 f g h a) where
--     zero (TC.Comp1 x) = TC.Comp1 (zero x)
--     {-# INLINE zero #-}
--     add (TC.Comp1 x) (TC.Comp1 y) = TC.Comp1 (add x y)
--     {-# INLINE add #-}
--     one (TC.Comp1 x) = TC.Comp1 (one x)
--     {-# INLINE one #-}

-- -- | @since 0.2.2.0
-- instance Backprop (f (g a)) => Backprop ((f TC.:.: g) a) where
--     zero (Comp x) = Comp (zero x)
--     {-# INLINE zero #-}
--     add (Comp x) (Comp y) = Comp (add x y)
--     {-# INLINE add #-}
--     one (Comp x) = Comp (one x)
--     {-# INLINE one #-}

-- -- | @since 0.2.2.0
-- instance Backprop w => Backprop (TC.C w a) where
--     zero (TC.C x) = TC.C (zero x)
--     {-# INLINE zero #-}
--     add (TC.C x) (TC.C y) = TC.C (add x y)
--     {-# INLINE add #-}
--     one (TC.C x) = TC.C (one x)
--     {-# INLINE one #-}

-- -- | @since 0.2.2.0
-- instance Backprop (p a b) => Backprop (Flip p b a) where
--     zero (Flip x) = Flip (zero x)
--     {-# INLINE zero #-}
--     add (Flip x) (Flip y) = Flip (add x y)
--     {-# INLINE add #-}
--     one (Flip x) = Flip (one x)
--     {-# INLINE one #-}

-- -- | @since 0.2.2.0
-- instance Backprop (p '(a, b)) => Backprop (Cur p a b) where
--     zero (Cur x) = Cur (zero x)
--     {-# INLINE zero #-}
--     add (Cur x) (Cur y) = Cur (add x y)
--     {-# INLINE add #-}
--     one (Cur x) = Cur (one x)
--     {-# INLINE one #-}

-- -- | @since 0.2.2.0
-- instance Backprop (p a b) => Backprop (Uncur p '(a, b)) where
--     zero (Uncur x) = Uncur (zero x)
--     {-# INLINE zero #-}
--     add (Uncur x) (Uncur y) = Uncur (add x y)
--     {-# INLINE add #-}
--     one (Uncur x) = Uncur (one x)
--     {-# INLINE one #-}

-- -- | @since 0.2.2.0
-- instance Backprop (p '(a, b, c)) => Backprop (Cur3 p a b c) where
--     zero (Cur3 x) = Cur3 (zero x)
--     {-# INLINE zero #-}
--     add (Cur3 x) (Cur3 y) = Cur3 (add x y)
--     {-# INLINE add #-}
--     one (Cur3 x) = Cur3 (one x)
--     {-# INLINE one #-}

-- -- | @since 0.2.2.0
-- instance Backprop (p a b c) => Backprop (Uncur3 p '(a, b, c)) where
--     zero (Uncur3 x) = Uncur3 (zero x)
--     {-# INLINE zero #-}
--     add (Uncur3 x) (Uncur3 y) = Uncur3 (add x y)
--     {-# INLINE add #-}
--     one (Uncur3 x) = Uncur3 (one x)
--     {-# INLINE one #-}

-- -- | @since 0.2.2.0
-- instance Backprop (f a a) => Backprop (Join f a) where
--     zero (Join x) = Join (zero x)
--     {-# INLINE zero #-}
--     add (Join x) (Join y) = Join (add x y)
--     {-# INLINE add #-}
--     one (Join x) = Join (one x)
--     {-# INLINE one #-}

-- -- | @since 0.2.2.0
-- instance Backprop (t (Flip f b) a) => Backprop (Conj t f a b) where
--     zero (Conj x) = Conj (zero x)
--     {-# INLINE zero #-}
--     add (Conj x) (Conj y) = Conj (add x y)
--     {-# INLINE add #-}
--     one (Conj x) = Conj (one x)
--     {-# INLINE one #-}

-- -- | @since 0.2.2.0
-- instance Backprop (c (f a)) => Backprop (LL c a f) where
--     zero (LL x) = LL (zero x)
--     {-# INLINE zero #-}
--     add (LL x) (LL y) = LL (add x y)
--     {-# INLINE add #-}
--     one (LL x) = LL (one x)
--     {-# INLINE one #-}

-- -- | @since 0.2.2.0
-- instance Backprop (c (f a)) => Backprop (RR c f a) where
--     zero (RR x) = RR (zero x)
--     {-# INLINE zero #-}
--     add (RR x) (RR y) = RR (add x y)
--     {-# INLINE add #-}
--     one (RR x) = RR (one x)
--     {-# INLINE one #-}

-- | @since 0.2.2.0
instance Backprop a => Backprop (K1 i a p)

-- | @since 0.2.2.0
instance Backprop (f p) => Backprop (M1 i c f p)

-- | @since 0.2.2.0
instance (Backprop (f p), Backprop (g p)) => Backprop ((f :*: g) p)

-- | @since 0.2.2.0
instance Backprop (V1 p)

-- | @since 0.2.2.0
instance Backprop (U1 p)

-- | @since 0.2.2.0
instance Backprop a => Backprop (Sum a)

-- | @since 0.2.2.0
instance Backprop a => Backprop (Product a)

-- | @since 0.2.2.0
instance Backprop a => Backprop (SG.Option a)

-- | @since 0.2.2.0
instance Backprop a => Backprop (SG.First a)

-- | @since 0.2.2.0
instance Backprop a => Backprop (SG.Last a)

-- | @since 0.2.2.0
instance Backprop a => Backprop (First a)

-- | @since 0.2.2.0
instance Backprop a => Backprop (Data.Monoid.Last a)

-- | @since 0.2.2.0
instance Backprop a => Backprop (Dual a)

-- | @since 0.2.2.0
instance (Backprop a, Backprop b) => Backprop (SG.Arg a b)

-- | @since 0.2.2.0
instance (Backprop (f a), Backprop (g a)) => Backprop (DFP.Product f g a)

-- | @since 0.2.2.0
instance Backprop (f (g a)) => Backprop (Compose f g a)

-- | 'add' adds together results; 'zero' and 'one' act on results.
--
-- @since 0.2.2.0
instance Backprop a => Backprop (r -> a) where
    zero = zeroFunctor
    {-# INLINE zero #-}
    add  = liftA2 add
    {-# INLINE add #-}
    one  = oneFunctor
    {-# INLINE one #-}

-- | @since 0.2.2.0
instance (Backprop a, Applicative m) => Backprop (Arr.Kleisli m r a) where
    zero (Arr.Kleisli f) = Arr.Kleisli ((fmap . fmap) zero f)
    {-# INLINE zero #-}
    add (Arr.Kleisli f) (Arr.Kleisli g) = Arr.Kleisli $ \x ->
        add <$> f x <*> g x
    one (Arr.Kleisli f) = Arr.Kleisli ((fmap . fmap) one f)
    {-# INLINE one #-}
