{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-orphans #-}
{-|
  This module contains PostgreSQL-specific JSON functions.

  A couple of things to keep in mind about this module:

      * The @Type@ column in the PostgreSQL documentation tables
      are the types of the right operand, the left is always @jsonb@.
      * This module also exports 'PersistField' and 'PersistFieldSql'
      orphan instances for 'Data.Aeson.Value'
      * Since these operators can all take @NULL@ values as their input,
      and most can also output @NULL@ values (even when the inputs are
      guaranteed to not be NULL), all 'Data.Aeson.Value's are wrapped in
      'Maybe'. This also makes it easier to chain them.
      Just use the 'just' function to lift any non-'Maybe' JSON values
      in case it doesn't type check.
      * As long as the previous operator's resulting value is
      'Maybe' 'Data.Aeson.Value', any other JSON operator can be
      used to transform the JSON further.

  /The PostgreSQL version the functions work with are included/
  /in their description./

  /Since: 3.1.0/
-}
module Database.Esqueleto.PostgreSQL.JSON
  ( -- * Arrow operators
    --
    -- /Better documentation included with individual functions/
    --
    -- === __PostgreSQL Documentation__
    --
    -- /Works with any PostgreSQL of version >= 9.3/
    --
    -- @
    --      | Type   | Description                                |  Example                                         | Example Result
    -- -----+--------+--------------------------------------------+--------------------------------------------------+----------------
    --  ->  | int    | Get JSON array element (indexed from zero, | '[{"a":"foo"},{"b":"bar"},{"c":"baz"}]'::json->2 | {"c":"baz"}
    --      |        | negative integers count from the end)      |                                                  |
    --  ->  | text   | Get JSON object field by key               | '{"a": {"b":"foo"}}'::json->'a'                  | {"b":"foo"}
    --  ->> | int    | Get JSON array element as text             | '[1,2,3]'::json->>2                              | 3
    --  ->> | text   | Get JSON object field as text              | '{"a":1,"b":2}'::json->>'b'                      | 2
    --  #>  | text[] | Get JSON object at specified path          | '{"a": {"b":{"c": "foo"}}}'::json#>'{a,b}'       | {"c": "foo"}
    --  #>> | text[] | Get JSON object at specified path as text  | '{"a":[1,2,3],"b":[4,5,6]}'::json#>>'{a,2}'      | 3
    -- @
    (->.)
  , (->>.)
  , (#>.)
  , (#>>.)
  -- * Filter operators
  --
  -- /Better documentation included with individual functions/
  --
  -- === __PostgreSQL Documentation__
  --
  -- /Works with any PostgreSQL of version >= 9.4/
  --
  -- @
  --     | Type   | Description                                                     |  Example
  -- ----+--------+-----------------------------------------------------------------+---------------------------------------------------
  --  @> | jsonb  | Does the left JSON value contain within it the right value?     | '{"a":1, "b":2}'::jsonb @> '{"b":2}'::jsonb
  --  <@ | jsonb  | Is the left JSON value contained within the right value?        | '{"b":2}'::jsonb <@ '{"a":1, "b":2}'::jsonb
  --  ?  | text   | Does the string exist as a top-level key within the JSON value? | '{"a":1, "b":2}'::jsonb ? 'b'
  --  ?| | text[] | Do any of these array strings exist as top-level keys?          | '{"a":1, "b":2, "c":3}'::jsonb ?| array['b', 'c']
  --  ?& | text[] | Do all of these array strings exist as top-level keys?          | '["a", "b"]'::jsonb ?& array['a', 'b']
  -- @
  , (@>.)
  , (<@.)
  , (?.)
  , (?|.)
  , (?&.)
  -- * Deletion and concatenation operators
  --
  -- /Better documentation included with individual functions/
  --
  -- === __PostgreSQL Documentation__
  --
  -- /Works with any PostgreSQL of version >= 9.5/
  --
  -- @
  --     | Type    | Description                                                            |  Example
  -- ----+---------+------------------------------------------------------------------------+-------------------------------------------------
  --  || | jsonb   | Concatenate two jsonb values into a new jsonb value                    | '["a", "b"]'::jsonb || '["c", "d"]'::jsonb
  --  -  | text    | Delete key/value pair or string element from left operand.             | '{"a": "b"}'::jsonb - 'a'
  --     |         | Key/value pairs are matched based on their key value.                  |
  --  -  | text[]  | Delete multiple key/value pairs or string elements from left operand.  | '{"a": "b", "c": "d"}'::jsonb - '{a,c}'::text[]
  --     |         | Key/value pairs are matched based on their key value.                  |
  --  -  | integer | Delete the array element with specified index (Negative integers count | '["a", "b"]'::jsonb - 1
  --     |         | from the end). Throws an error if top level container is not an array. |
  --  #- | text[]  | Delete the field or element with specified path                        | '["a", {"b":1}]'::jsonb #- '{1,b}'
  --     |         | (for JSON arrays, negative integers count from the end)                |
  -- @
  , (||.)
  , (-.)
  , (#-.)
  ) where

#if __GLASGOW_HASKELL__ < 804
import Data.Semigroup
#endif
import Data.Aeson (encode, eitherDecodeStrict)
import qualified Data.Aeson as Aeson (Value)
import qualified Data.ByteString.Lazy as BSL (toStrict)
import Data.Text (Text)
import qualified Data.Text as T (concat, intercalate, pack)
import qualified Data.Text.Encoding as TE (decodeUtf8, encodeUtf8)
import Database.Esqueleto.Internal.Language hiding ((?.), (-.), random_)
import Database.Esqueleto.Internal.PersistentImport
import Database.Esqueleto.Internal.Sql


infixl 6 ->., ->>., #>., #>>.
infixl 6 @>., <@., ?., ?|., ?&.
infixl 6 -., #-.


-- | This function extracts the jsonb value from a JSON array or object,
-- depending on whether you use an @int@ (@Left i@ in Haskell) or a
-- @text@ (@Right t@ in Haskell).
--
-- As long as the left operand is @jsonb@, this function will not
-- throw an exception, but will return @NULL@ when an @int@ is used on
-- anything other than a JSON array, or a @text@ is used on anything
-- other than a JSON object.
-- This does mean you can use the 'isNothing' function.
--
-- === __PostgreSQL Documentation__
--
-- /Works with any PostgreSQL of version >= 9.3/
--
-- @
--     | Type | Description                                |  Example                                         | Example Result
-- ----+------+--------------------------------------------+--------------------------------------------------+----------------
--  -> | int  | Get JSON array element (indexed from zero) | '[{"a":"foo"},{"b":"bar"},{"c":"baz"}]'::json->2 | {"c":"baz"}
--  -> | text | Get JSON object field by key               | '{"a": {"b":"foo"}}'::json->'a'                  | {"b":"foo"}
-- @
--
-- /Since: 3.1.0/
(->.) :: SqlExpr (Value (Maybe Aeson.Value))
      -> Either Int Text
      -> SqlExpr (Value (Maybe Aeson.Value))
(->.) value (Right txt) = unsafeSqlBinOp " -> " value $ val txt
(->.) value (Left i)    = unsafeSqlBinOp " -> " value $ val i

-- | Identical to '->.', but the resulting DB type is a @text@,
-- so it could be chained with anything that uses @text@.
--
-- === __PostgreSQL Documentation__
--
-- /Works with any PostgreSQL of version >= 9.3/
--
-- @
--      | Type | Description                    |  Example                    | Example Result
-- -----+------+--------------------------------+-----------------------------+----------------
--  ->> | int  | Get JSON array element as text | '[1,2,3]'::json->>2         | 3
--  ->> | text | Get JSON object field as text  | '{"a":1,"b":2}'::json->>'b' | 2
-- @
--
-- /Since: 3.1.0/
(->>.) :: SqlExpr (Value (Maybe Aeson.Value))
       -> Either Int Text
       -> SqlExpr (Value (Maybe Text))
(->>.) value (Right txt) = unsafeSqlBinOp " ->> " value $ val txt
(->>.) value (Left i)    = unsafeSqlBinOp " ->> " value $ val i

-- | This operator can be used to select a JSON value from deep inside another one.
-- It only works on objects and arrays and will result in @NULL@ ('Nothing') when
-- encountering any other JSON type.
--
-- The 'Text's used in the right operand list will always select an object field, but
-- can also select an index from a JSON array if that text is parsable as an integer.
--
-- Consider the following:
--
-- @
-- x ^. TestBody #>. ["0","1"]
-- @
--
-- The following JSON values in the @x@ table's @body@ column will be affected:
--
-- @
--  Value in row                         | Resulting value
-- --------------------------------------+----------------------------
-- {"0":{"1":"Got it!"}}                 | "Got it!"
-- {"0":[null,["Got it!","Even here!"]]} | ["Got it!", "Even here!"]
-- [{"1":"Got it again!"}]               | "Got it again!"
-- [[null,{"Wow":"so deep!"}]]           | {"Wow": "so deep!"}
-- false                                 | NULL
-- "nope"                                | NULL
-- 3.14                                  | NULL
-- @
--
-- === __PostgreSQL Documentation__
--
-- /Works with any PostgreSQL of version >= 9.3/
--
-- @
--      | Type   | Description                       |  Example                                   | Example Result
-- -----+--------+-----------------------------------+--------------------------------------------+----------------
--  #>  | text[] | Get JSON object at specified path | '{"a": {"b":{"c": "foo"}}}'::json#>'{a,b}' | {"c": "foo"}
-- @
--
-- /Since: 3.1.0/
(#>.) :: SqlExpr (Value (Maybe Aeson.Value))
      -> [Text]
      -> SqlExpr (Value (Maybe Aeson.Value))
(#>.) value = unsafeSqlBinOp " #> " value . mkTextArray


-- | This function is to '#>.' as '->>.' is to '->.'
--
-- === __PostgreSQL Documentation__
--
-- /Works with any PostgreSQL of version >= 9.3/
--
-- @
--      | Type   | Description                               |  Example                                    | Example Result
-- -----+--------+-------------------------------------------+---------------------------------------------+----------------
--  #>> | text[] | Get JSON object at specified path as text | '{"a":[1,2,3],"b":[4,5,6]}'::json#>>'{a,2}' | 3
-- @
--
-- /Since: 3.1.0/
(#>>.) :: SqlExpr (Value (Maybe Aeson.Value))
       -> [Text]
       -> SqlExpr (Value (Maybe Text))
(#>>.)  value = unsafeSqlBinOp " #>> " value . mkTextArray

-- | This operator checks for the JSON value on the right to be a subset
-- of the JSON value on the left.
--
-- Examples of the usage of this operator can be found in
-- the Database.Persist.Postgresql.JSON module. (here:
-- <https://hackage.haskell.org/package/persistent-postgresql-2.10.0/docs/Database-Persist-Postgresql-JSON.html>)
--
-- === __PostgreSQL Documentation__
--
-- /Works with any PostgreSQL of version >= 9.4/
--
-- @
--     | Type  | Description                                                 |  Example
-- ----+-------+-------------------------------------------------------------+---------------------------------------------
--  @> | jsonb | Does the left JSON value contain within it the right value? | '{"a":1, "b":2}'::jsonb @> '{"b":2}'::jsonb
-- @
--
-- /Since: 3.1.0/
(@>.) :: SqlExpr (Value (Maybe Aeson.Value))
      -> SqlExpr (Value (Maybe Aeson.Value))
      -> SqlExpr (Value Bool)
(@>.) = unsafeSqlBinOp " @> "

-- | This operator works the same as '@>.', just with the arguments flipped.
-- So it checks for the JSON value on the left to be a subset of JSON value on the right.
--
-- Examples of the usage of this operator can be found in
-- the Database.Persist.Postgresql.JSON module. (here:
-- <https://hackage.haskell.org/package/persistent-postgresql-2.10.0/docs/Database-Persist-Postgresql-JSON.html>)
--
-- === __PostgreSQL Documentation__
--
-- /Works with any PostgreSQL of version >= 9.4/
--
-- @
--     | Type  | Description                                              |  Example
-- ----+-------+----------------------------------------------------------+---------------------------------------------
--  <@ | jsonb | Is the left JSON value contained within the right value? | '{"b":2}'::jsonb <@ '{"a":1, "b":2}'::jsonb
-- @
--
-- /Since: 3.1.0/
(<@.) :: SqlExpr (Value (Maybe Aeson.Value))
      -> SqlExpr (Value (Maybe Aeson.Value))
      -> SqlExpr (Value Bool)
(<@.) = unsafeSqlBinOp " <@ "

-- | This operator checks if the given text is a top-level member of the
-- JSON value on the left. This means a top-level field in an object, a
-- top-level string in an array or just a string value.
--
-- Examples of the usage of this operator can be found in
-- the Database.Persist.Postgresql.JSON module. (here:
-- <https://hackage.haskell.org/package/persistent-postgresql-2.10.0/docs/Database-Persist-Postgresql-JSON.html>)
--
-- === __PostgreSQL Documentation__
--
-- /Works with any PostgreSQL of version >= 9.4/
--
-- @
--    | Type | Description                                                     |  Example
-- ---+------+-----------------------------------------------------------------+-------------------------------
--  ? | text | Does the string exist as a top-level key within the JSON value? | '{"a":1, "b":2}'::jsonb ? 'b'
-- @
--
-- /Since: 3.1.0/
(?.) :: SqlExpr (Value (Maybe Aeson.Value))
     -> Text
     -> SqlExpr (Value Bool)
(?.) value = unsafeSqlBinOp " ?? " value . val

-- | This operator checks if __ANY__ of the given texts is a top-level member
-- of the JSON value on the left. This means any top-level field in an object,
-- any top-level string in an array or just a string value.
--
-- Examples of the usage of this operator can be found in
-- the Database.Persist.Postgresql.JSON module. (here:
-- <https://hackage.haskell.org/package/persistent-postgresql-2.10.0/docs/Database-Persist-Postgresql-JSON.html>)
--
-- === __PostgreSQL Documentation__
--
-- /Works with any PostgreSQL of version >= 9.4/
--
-- @
--     | Type   | Description                                            |  Example
-- ----+--------+--------------------------------------------------------+---------------------------------------------------
--  ?| | text[] | Do any of these array strings exist as top-level keys? | '{"a":1, "b":2, "c":3}'::jsonb ?| array['b', 'c']
-- @
--
-- /Since: 3.1.0/
(?|.) :: SqlExpr (Value (Maybe Aeson.Value))
      -> [Text]
      -> SqlExpr (Value Bool)
(?|.) value = unsafeSqlBinOp " ??| " value . mkTextArray

-- | This operator checks if __ALL__ of the given texts are top-level members
-- of the JSON value on the left. This means a top-level field in an object,
-- a top-level string in an array or just a string value.
--
-- Examples of the usage of this operator can be found in
-- the Database.Persist.Postgresql.JSON module. (here:
-- <https://hackage.haskell.org/package/persistent-postgresql-2.10.0/docs/Database-Persist-Postgresql-JSON.html>)
--
-- === __PostgreSQL Documentation__
--
-- /Works with any PostgreSQL of version >= 9.4/
--
-- @
--     | Type   | Description                                            |  Example
-- ----+--------+--------------------------------------------------------+----------------------------------------
--  ?& | text[] | Do all of these array strings exist as top-level keys? | '["a", "b"]'::jsonb ?& array['a', 'b']
-- @
--
-- /Since: 3.1.0/
(?&.) :: SqlExpr (Value (Maybe Aeson.Value))
      -> [Text]
      -> SqlExpr (Value Bool)
(?&.) value = unsafeSqlBinOp " ??& " value . mkTextArray

-- | This operator concatenates two JSON values. The behaviour is
-- self-evident when used on two arrays, but the behaviour on different
-- combinations of JSON values might behave unexpectedly.
--
-- __CAUTION: THIS FUNCTION THROWS AN EXCEPTION WHEN CONCATENATING__
-- __A JSON OBJECT WITH A JSON SCALAR VALUE!__
--
-- === __Arrays__
--
-- This operator is a standard concatenation function when used on arrays:
--
-- @
-- [1,2]   || [2,3]   == [1,2,2,3]
-- []      || [1,2,3] == [1,2,3]
-- [1,2,3] || []      == [1,2,3]
-- @
--
-- === __Objects__
-- When concatenating JSON objects with other JSON objects, the fields
-- from the JSON object on the right are added to the JSON object on the
-- left. When concatenating a JSON object with a JSON array, the object
-- will be inserted into the array; either on the left or right, depending
-- on the position relative to the operator.
--
-- When concatening an object with a scalar value, an exception is thrown.
--
-- @
-- {"a": 3.14}                    || {"b": true}         == {"a": 3.14, "b": true}
-- {"a": "b"}                     || {"a": null}         == {"a": null}
-- {"a": {"b": true, "c": false}} || {"a": {"b": false}} == {"a": {"b": false}}
-- {"a": 3.14}                    || [1,null]            == [{"a": 3.14},1,null]
-- [1,null]                       || {"a": 3.14}         == [1,null,{"a": 3.14}]
-- 1                              || {"a": 3.14}         == ERROR: invalid concatenation of jsonb objects
-- @
--
-- === __Scalar values__
--
-- Scalar values can be thought of as being singleton arrays when
-- used with this operator. This rule does not apply when concatenating
-- with JSON objects.
--
-- @
-- 1          || null       == [1,null]
-- true       || "a"        == [true,"a"]
-- [1,2]      || false      == [1,2,false]
-- null       || [1,"a"]    == [null,1,"a"]
-- {"a":3.14} || true       == ERROR: invalid concatenation of jsonb objects
-- {"a":3.14} || [true]     == [{"a":3.14},true]
-- [false]    || {"a":3.14} == [false,{"a":3.14}]
-- @
--
-- === __PostgreSQL Documentation__
--
-- /Works with any PostgreSQL of version >= 9.5/
--
-- @
--     | Type  | Description                                         |  Example
-- ----+-------+-----------------------------------------------------+--------------------------------------------
--  || | jsonb | Concatenate two jsonb values into a new jsonb value | '["a", "b"]'::jsonb || '["c", "d"]'::jsonb
-- @
--
-- /Note: The @||@ operator concatenates the elements at the top level of/
-- /each of its operands. It does not operate recursively. For example, if/
-- /both operands are objects with a common key field name, the value of the/
-- /field in the result will just be the value from the right hand operand./
--
-- @since 3.1.0
(||.) :: SqlExpr (Value (Maybe Aeson.Value))
      -> SqlExpr (Value (Maybe Aeson.Value))
      -> SqlExpr (Value (Maybe Aeson.Value))
(||.) = unsafeSqlBinOp " || "

-- | This operator can remove keys from an object, or string elements from an array
-- when using text, and remove certain elements by index when using integers.
--
-- __CAUTION: THIS FUNCTION THROWS AN EXCEPTION WHEN USED ON ANYTHING OTHER__
-- __THAN OBJECTS OR ARRAYS WHEN USING TEXT, AND ANYTHING OTHER THAN ARRAYS__
-- __WHEN USING INTEGERS!__
--
-- === __Objects__
--
-- @
-- {"a": 3.14}            - []          == {"a": 3.14}
-- {"a": 3.14}            - ["a"]       == {}
-- {"a": "b"}             - ["b"]       == {"a": "b"}
-- {"a": 3.14}            - ["a","b"]   == {}
-- {"a": 3.14, "c": true} - ["a","b"]   == {"c": true}
-- ["a", 2, "c"]          - ["a","b"]   == [2, "c"] -- can remove strings from arrays
-- [true, "b", 5]         - 0           == ["b", 5]
-- [true, "b", 5]         - 3           == [true, "b", 5]
-- [true, "b", 5]         - -1          == [true, "b"]
-- [true, "b", 5]         - -4          == [true, "b", 5]
-- []                     - 1           == []
-- {"1": true}            - 1           == ERROR: cannot delete from object using integer index
-- 1                      - <anything>  == ERROR: cannot delete from scalar
-- "a"                    - <anything>  == ERROR: cannot delete from scalar
-- true                   - <anything>  == ERROR: cannot delete from scalar
-- null                   - <anything>  == ERROR: cannot delete from scalar
-- @
--
-- === __PostgreSQL Documentation__
--
-- /Works with any PostgreSQL of version >= 9.5/
--
-- @
--    | Type    | Description                                                            |  Example
-- ---+---------+------------------------------------------------------------------------+-------------------------------------------------
--  - | text    | Delete key/value pair or string element from left operand.             | '{"a": "b"}'::jsonb - 'a'
--    |         | Key/value pairs are matched based on their key value.                  |
--  - | text[]  | Delete multiple key/value pairs or string elements from left operand.  | '{"a": "b", "c": "d"}'::jsonb - '{a,c}'::text[]
--    |         | Key/value pairs are matched based on their key value.                  |
--  - | integer | Delete the array element with specified index (Negative integers count | '["a", "b"]'::jsonb - 1
--    |         | from the end). Throws an error if top level container is not an array. |
-- @
--
-- /Since: 3.1.0/
(-.) :: SqlExpr (Value (Maybe Aeson.Value))
     -> Either Int [Text]
     -> SqlExpr (Value (Maybe Aeson.Value))
(-.) value (Right ts) = unsafeSqlBinOp " - " value $ mkTextArray ts
(-.) value (Left i) = unsafeSqlBinOp " - " value $ val i

-- | This operator can remove elements nested in an object.
-- If a 'Text' is not parsable as a number when selecting in an array
-- (even when halfway through the selection)
--
-- __CAUTION: THIS FUNCTION THROWS AN EXCEPTION WHEN USED__
-- __ON ANYTHING OTHER THAN OBJECTS OR ARRAYS, AND WILL__
-- __ALSO THROW WHEN TRYING TO SELECT AN ARRAY ELEMENT WITH__
-- __A NON-INTEGER TEXT__ (cf. examples)
--
-- === __Objects__
--
-- @
-- {"a": 3.14, "b": null}        #- []        == {"a": 3.14, "b": null}
-- {"a": 3.14, "b": null}        #- ["a"]     == {"b": null}
-- {"a": 3.14, "b": null}        #- ["a","b"] == {"a": 3.14, "b": null}
-- {"a": {"b":false}, "b": null} #- ["a","b"] == {"a": {}, "b": null}
-- @
--
-- === __Arrays__
--
-- [true, {"b":null}, 5]       #- []            == [true, {"b":null}, 5]
-- [true, {"b":null}, 5]       #- ["0"]         == [{"b":null}, 5]
-- [true, {"b":null}, 5]       #- ["b"]         == ERROR: path element at position 1 is not an integer: "b"
-- [true, {"b":null}, 5]       #- ["0","b"]     == [true, {}, 5]
-- {"a": {"b":[false,4,null]}} #- ["a","b","2"] == {"a": {"b":[false,4]}}
-- {"a": {"b":[false,4,null]}} #- ["a","b","c"] == ERROR: path element at position 3 is not an integer: "c"
--
-- === __Other values__
--
-- 1    #- {anything} == ERROR: cannot delete from scalar
-- "a"  #- {anything} == ERROR: cannot delete from scalar
-- true #- {anything} == ERROR: cannot delete from scalar
-- null #- {anything} == ERROR: cannot delete from scalar
-- @
--
-- === __PostgreSQL Documentation__
--
-- /Works with any PostgreSQL of version >= 9.5/
--
-- @
--     | Type   | Description                                             |  Example
-- ----+--------+---------------------------------------------------------+------------------------------------
--  #- | text[] | Delete the field or element with specified path         | '["a", {"b":1}]'::jsonb #- '{1,b}'
--     |        | (for JSON arrays, negative integers count from the end) |
-- @
--
-- /Since: 3.1.0/
(#-.) :: SqlExpr (Value (Maybe Aeson.Value))
      -> [Text]
      -> SqlExpr (Value (Maybe Aeson.Value))
(#-.) value = unsafeSqlBinOp " #- " value . mkTextArray

mkTextArray :: [Text] -> SqlExpr (Value Text)
mkTextArray xs = val $ "{" <> T.intercalate "," xs <> "}" <> "::text[]"



--- ORPHAN INSTANCES ---
--- ORPHAN INSTANCES ---
--- ORPHAN INSTANCES ---



-- Mainly copied over from Database.Persist.Postgresql.JSON
-- Since we don't need anything else and adding another dependency
-- just for these two instances is a bit overkill.

-- | /Since: 3.1.0/
instance PersistField Aeson.Value where
  toPersistValue = PersistDbSpecific . BSL.toStrict . encode
  fromPersistValue pVal = case pVal of
      PersistByteString bs -> fromLeft (badParse $ TE.decodeUtf8 bs) $ eitherDecodeStrict bs
      PersistText t -> fromLeft (badParse t) $ eitherDecodeStrict (TE.encodeUtf8 t)
      x -> Left $ fromPersistValueError "string or bytea" x

-- | jsonb - /Since: 3.1.0/
instance PersistFieldSql Aeson.Value where
  sqlType _ = SqlOther "JSONB"

badParse :: Text -> String -> Text
badParse t = fromPersistValueParseError t . T.pack

fromLeft :: (a -> b) -> Either a x -> Either b x
fromLeft f (Left a) = Left $ f a
fromLeft _ (Right r) = Right r

fromPersistValueError
  :: Text -- ^ Database type(s), should appear different from Haskell name, e.g. "integer" or "INT", not "Int".
  -> PersistValue -- ^ Incorrect value
  -> Text -- ^ Error message
fromPersistValueError databaseType received = T.concat
    [ "Failed to parse Haskell type `Aeson.Value`; "
    , "expected ", databaseType
    , " from database, but received: ", T.pack (show received)
    , ". Potential solution: Check that your database schema matches your Persistent model definitions."
    ]

fromPersistValueParseError
  :: Text -- ^ Received value
  -> Text -- ^ Additional error
  -> Text -- ^ Error message
fromPersistValueParseError received err = T.concat
    [ "Failed to parse Haskell type `Aeson.Value`, "
    , "but received ", received
    , " | with error: ", err
    ]
