{-|
Module: Squeal.PostgreSQL.Expression.Array
Description: Array functions
Copyright: (c) Eitan Chatav, 2019
Maintainer: eitan@morphism.tech
Stability: experimental

Array functions
-}

{-# LANGUAGE
    AllowAmbiguousTypes
  , DataKinds
  , FlexibleContexts
  , FlexibleInstances
  , MultiParamTypeClasses
  , OverloadedLabels
  , OverloadedStrings
  , RankNTypes
  , ScopedTypeVariables
  , TypeApplications
  , TypeFamilies
  , TypeOperators
  , UndecidableInstances
#-}

module Squeal.PostgreSQL.Expression.Array
  ( array
  , array1
  , array2
  , cardinality
  , index
  , unnest
  ) where

import Data.String
import Data.Word (Word64)

import qualified Generics.SOP as SOP

import Squeal.PostgreSQL.Alias
import Squeal.PostgreSQL.Expression
import Squeal.PostgreSQL.Expression.Set
import Squeal.PostgreSQL.List
import Squeal.PostgreSQL.Render
import Squeal.PostgreSQL.Schema

-- $setup
-- >>> import Squeal.PostgreSQL

-- | >>> printSQL $ array [null_, false, true]
-- ARRAY[NULL, FALSE, TRUE]
array
  :: [Expression outer commons grp schemas params from ty]
  -- ^ array elements
  -> Expression outer commons grp schemas params from (null ('PGvararray ty))
array xs = UnsafeExpression $ "ARRAY" <>
  bracketed (commaSeparated (renderSQL <$> xs))

{- | construct a 1-dimensional fixed length array

>>> printSQL $ array1 (null_ :* false *: true)
ARRAY[NULL, FALSE, TRUE]

>>> :type array1 (null_ :* false *: true)
array1 (null_ :* false *: true)
  :: Expression
       outer
       commons
       grp
       schemas
       params
       from
       (null ('PGfixarray '[3] ('Null 'PGbool)))
-}
array1
  :: (n ~ Length tys, SOP.All ((~) ty) tys)
  => NP (Expression outer commons grp schemas params from) tys
  -> Expression outer commons grp schemas params from (null ('PGfixarray '[n] ty))
array1 xs = UnsafeExpression $ "ARRAY" <>
  bracketed (renderCommaSeparated renderSQL xs)

{- | construct a 2-dimensional fixed length array

>>> printSQL $ array2 ((null_ :* false *: true) *: (false :* null_ *: true))
ARRAY[[NULL, FALSE, TRUE], [FALSE, NULL, TRUE]]

>>> :type array2 ((null_ :* false *: true) *: (false :* null_ *: true))
array2 ((null_ :* false *: true) *: (false :* null_ *: true))
  :: Expression
       outer
       commons
       grp
       schemas
       params
       from
       (null ('PGfixarray '[2, 3] ('Null 'PGbool)))
-}
array2
  ::  ( SOP.All ((~) tys) tyss
      , SOP.All SOP.SListI tyss
      , Length tyss ~ n1
      , SOP.All ((~) ty) tys
      , Length tys ~ n2 )
  => NP (NP (Expression outer commons grp schemas params from)) tyss
  -> Expression outer commons grp schemas params from (null ('PGfixarray '[n1,n2] ty))
array2 xss = UnsafeExpression $ "ARRAY" <>
  bracketed (renderCommaSeparatedConstraint @SOP.SListI (bracketed . renderCommaSeparated renderSQL) xss)

-- | >>> printSQL $ cardinality (array [null_, false, true])
-- cardinality(ARRAY[NULL, FALSE, TRUE])
cardinality :: null ('PGvararray ty) --> null 'PGint8
cardinality = unsafeFunction "cardinality"

-- | >>> printSQL $ array [null_, false, true] & index 2
-- (ARRAY[NULL, FALSE, TRUE])[2]
index
  :: Word64 -- ^ index
  -> null ('PGvararray ty) --> NullifyType ty
index n expr = UnsafeExpression $
  parenthesized (renderSQL expr) <> "[" <> fromString (show n) <> "]"

-- | Expand an array to a set of rows
unnest :: SetFunction "unnest" (null ('PGvararray ty)) '["unnest" ::: ty]
unnest = unsafeSetFunction
