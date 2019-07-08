{-# LANGUAGE DeriveDataTypeable
           , EmptyDataDecls
           , FlexibleContexts
           , FlexibleInstances
           , FunctionalDependencies
           , MultiParamTypeClasses
           , TypeFamilies
           , UndecidableInstances
           , GADTs
 #-}
{-# LANGUAGE ConstraintKinds
           , EmptyDataDecls
           , FlexibleContexts
           , FlexibleInstances
           , FunctionalDependencies
           , GADTs
           , MultiParamTypeClasses
           , OverloadedStrings
           , UndecidableInstances
           , ScopedTypeVariables
           , InstanceSigs
           , Rank2Types
           , CPP
 #-}
-- | This is an internal module, anything exported by this module
-- may change without a major version bump.  Please use only
-- "Database.Esqueleto" if possible.
module Database.Esqueleto.Internal.Sql
  ( -- * The pretty face
    SqlQuery
  , SqlExpr(..)
  , SqlEntity
  , select
  , selectSource
  , delete
  , deleteCount
  , update
  , updateCount
  , insertSelect
  , insertSelectCount
    -- * The guts
  , unsafeSqlCase
  , unsafeSqlBinOp
  , unsafeSqlAppend
  , unsafeSqlBinOpComposite
  , unsafeSqlValue
  , unsafeSqlCastAs
  , unsafeSqlFunction
  , unsafeSqlExtractSubField
  , UnsafeSqlFunctionArgument
  , OrderByClause
  -- TODO: HACK
  , OrderByType(..)
  , rawSelectSource
  , runSource
  , rawEsqueleto
  , toRawSql
  , Mode(..)
  , NeedParens(..)
  , IdentState
  , initialIdentState
  , IdentInfo
  , SqlSelect(..)
  , veryUnsafeCoerceSqlExprValue
  , veryUnsafeCoerceSqlExprValueList
  -- * Helper functions
  , makeOrderByNoNewline
  , uncommas'
  , parens
  , toArgList
  , builderToText
  ) where
