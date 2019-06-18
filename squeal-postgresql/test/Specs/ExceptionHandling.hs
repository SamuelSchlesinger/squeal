{-# LANGUAGE
    DataKinds
  , StandaloneDeriving
  , GeneralizedNewtypeDeriving
  , DeriveGeneric
  , DuplicateRecordFields
  , FlexibleContexts
  , OverloadedLabels
  , OverloadedLists
  , OverloadedStrings
  , ScopedTypeVariables
  , TypeApplications
  , TypeFamilies
  , TypeInType
  , TypeOperators
#-}

module ExceptionHandling
  ( specs
  , User (..)
  ) where

import Control.Monad(void)
import Control.Monad.IO.Class (MonadIO (..))
import qualified Data.ByteString.Char8 as Char8
import Data.Int (Int16)
import Data.Text (Text)
import Data.Vector (Vector)
import qualified Generics.SOP as SOP
import qualified GHC.Generics as GHC
import Squeal.PostgreSQL
import Squeal.PostgreSQL.Migration
import Test.Hspec

type Schema =
  '[ "users" ::: 'Table (
       '[ "pk_users" ::: 'PrimaryKey '["id"]
        , "unique_names" ::: 'Unique '["name"]
        ] :=>
       '[ "id" ::: 'Def :=> 'NotNull 'PGint4
        , "name" ::: 'NoDef :=> 'NotNull 'PGtext
        , "vec" ::: 'NoDef :=> 'NotNull ('PGvararray ('Null 'PGint2))
        ])
   , "emails" ::: 'Table (
       '[  "pk_emails" ::: 'PrimaryKey '["id"]
        , "fk_user_id" ::: 'ForeignKey '["user_id"] "users" '["id"]
        ] :=>
       '[ "id" ::: 'Def :=> 'NotNull 'PGint4
        , "user_id" ::: 'NoDef :=> 'NotNull 'PGint4
        , "email" ::: 'NoDef :=> 'Null 'PGtext
        ])
   ]

type Schemas = Public Schema

data User =
  User { userName  :: Text
       , userEmail :: Maybe Text
       , userVec   :: VarArray (Vector (Maybe Int16)) }
  deriving (Show, GHC.Generic, Eq)
instance SOP.Generic User
instance SOP.HasDatatypeInfo User

setup :: Definition (Public '[]) Schemas
setup =
  createTable #users
    ( serial `as` #id :*
      (text & notNullable) `as` #name :*
      (vararray int2 & notNullable) `as` #vec )
    ( primaryKey #id `as` #pk_users
    :* unique #name `as` #unique_names )
  >>>
  createTable #emails
    ( serial `as` #id :*
      (int & notNullable) `as` #user_id :*
      (text & nullable) `as` #email )
    ( primaryKey #id `as` #pk_emails :*
      foreignKey #user_id #users #id
        OnDeleteCascade OnUpdateCascade `as` #fk_user_id )

teardown :: Definition Schemas (Public '[])
teardown = dropTable #emails >>> dropTable #users

migration :: Migration Definition (Public '[]) Schemas
migration = Migration { name = "test"
                      , up = setup
                      , down = teardown }

setupDB :: IO ()
setupDB = void . withConnection connectionString $
  manipulate (UnsafeManipulation "SET client_min_messages TO WARNING;")
  & pqThen (migrateUp (single migration))

dropDB :: IO ()
dropDB = void . withConnection connectionString $
  manipulate (UnsafeManipulation "SET client_min_messages TO WARNING;")
  & pqThen (migrateDown (single migration))

connectionString :: Char8.ByteString
connectionString = "postgres:///exampledb"

testUser :: User
testUser = User "TestUser" Nothing (VarArray [])

badTestUser :: User
badTestUser = User "TestUser\NUL1" Nothing (VarArray [])

newUser :: (MonadIO m, MonadPQ Schemas m) => User -> m ()
newUser u = void $ manipulateParams insertUser u


insertUser :: Manipulation_ Schemas User ()
insertUser = with (u `as` #u) e
    where
      u = insertInto #users
        (Values_ (Default `as` #id :* Set (param @1) `as` #name :* Set (param @3) `as` #vec) )
        OnConflictDoRaise (Returning_ (#id :* param @2 `as` #email))
      e = insertInto_ #emails $ Select
        (Default `as` #id :* Set (#u ! #id) `as` #user_id :* Set (#u ! #email) `as` #email)
        (from (common #u))

getUsers :: Query_ Schemas () User
getUsers = select_
    (#u ! #name `as`  #userName :*
     #e ! #email `as` #userEmail :*
     #u ! #vec `as`   #userVec )
    ( from (table (#users `as` #u)
         & innerJoin (table (#emails `as` #e ) )
           (#u ! #id .== #e ! #user_id   )))

specs :: SpecWith ()
specs = before_ setupDB $ after_ dropDB $
  describe "Exceptions" $ do

    let
      dupKeyErr = PQException $ PQState FatalError (Just "23505")
        (Just "ERROR:  duplicate key value violates unique constraint \"unique_names\"\nDETAIL:  Key (name)=(TestUser) already exists.\n")

    it "should be thrown for unique constraint violation in a manipulation" $
      withConnection connectionString insertUserTwice
       `shouldThrow` (== dupKeyErr)

    it "should be rethrown for unique constraint violation in a manipulation by a transaction" $
      withConnection connectionString (transactionally_ insertUserTwice)
       `shouldThrow` (== dupKeyErr)

    it "should be able to insert and then read a user" $ do
      fetchedUsers <- withConnection connectionString $ do
        newUser badTestUser
        getRows =<< runQuery getUsers
      fetchedUsers `shouldBe` [badTestUser]
