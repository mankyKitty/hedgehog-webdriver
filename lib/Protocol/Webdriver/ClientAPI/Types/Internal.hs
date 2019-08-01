{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveFunctor         #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeFamilies          #-}
module Protocol.Webdriver.ClientAPI.Types.Internal where

import           Control.Error.Util         (note)
import           Control.Lens               (over, (%~), (?~), _head)

import           Control.Monad.Error.Lens   (throwing)

import           Data.Bifunctor             (bimap)

import Data.Bool (bool)

import           Data.ByteString            (ByteString)
import qualified Data.ByteString            as BS
import qualified Data.ByteString.Base64     as B64
import qualified Data.ByteString.Char8      as B8
import qualified Data.ByteString.Lazy       as BSL
import qualified Data.ByteString.Lazy.Char8 as B8L

import qualified Data.Char                  as C

import           Data.Dependent.Map         (DMap, GCompare)
import qualified Data.Dependent.Map         as DM
import           Data.Dependent.Map.Lens    (dmat)

import           Data.Function              ((&))
import           Data.Functor               ((<&>))
import           Data.Functor.Contravariant ((>$<))
import           Data.Functor.Identity      (Identity (..))

import           Data.Text                  (Text)
import qualified Data.Text                  as T
import           Data.Vector                (Vector)
import qualified Data.Vector                as V
import           Text.Read                  (readMaybe)

import qualified Waargonaut.Decode          as D
import qualified Waargonaut.Decode.Error    as DE
import qualified Waargonaut.Encode          as E
import           Waargonaut.Generic         (JsonDecode (..), JsonEncode (..),
                                             Options (_optionsFieldName),
                                             defaultOpts, trimPrefixLowerFirst,
                                             untag)
data WDJson

instance JsonDecode WDJson BSL.ByteString where
  mkDecoder = pure D.lazyByteString

instance JsonDecode WDJson BS.ByteString where
  mkDecoder = pure D.strictByteString

-- If my understanding is correct, going from Word8 -> Char should be lossless
-- as there is no truncation because Char > Word8. This is different to using
-- the encoding functions to produce a text value as there are valid ByteStrings
-- that are not valid UTF-8 because ByteStrings are just arrays of bytes and are
-- not required to be valid UTF-8
encodeStrictByteString :: Applicative f => E.Encoder f BS.ByteString
encodeStrictByteString = B8.unpack >$< E.string

encodeLazyByteString :: Applicative f => E.Encoder f BSL.ByteString
encodeLazyByteString = B8L.unpack >$< E.string

instance JsonEncode WDJson BS.ByteString where
  mkEncoder = pure encodeStrictByteString

instance JsonEncode WDJson BSL.ByteString where
  mkEncoder = pure encodeLazyByteString

-- Used in the HollowBody so () is encoded as {}, as Webdriver endpoints can not
-- require any input in the body of a request but the driver will fail if there
-- isn't at least a JSON object.
instance JsonEncode WDJson () where
  mkEncoder = pure (E.mapLikeObj (const id))

withA :: Monad f => D.Decoder f a -> (a -> Either Text b) -> D.Decoder f b
withA from to = from >>= either (throwing DE._ConversionFailure) pure . to

withString :: Monad f => (String -> Either Text a) -> D.Decoder f a
withString = withA D.string

withText :: Monad f => (Text -> Either Text a) -> D.Decoder f a
withText = withA D.text

textMatch t x a = withText (bool (Left t) (Right a) . (== x))

decodeFromReadUCFirst :: (Read a, Monad f) => Text -> D.Decoder f a
decodeFromReadUCFirst l = withString (note l . readMaybe . over _head C.toUpper)

encodeToLower :: Applicative f => (a -> String) -> E.Encoder f a
encodeToLower f = T.toLower . T.pack . f >$< E.text

encodeShowToLower :: (Show a, Applicative f) => E.Encoder f a
encodeShowToLower = encodeToLower show

singleValueObj :: Applicative f => Text -> E.Encoder' a -> E.Encoder f a
singleValueObj k = E.mapLikeObj . E.atKey' k

trimWaargOpts :: Text -> Options
trimWaargOpts s = defaultOpts { _optionsFieldName = trimPrefixLowerFirst s }

infixr 2 ~=>

(~=>) :: (GCompare k, Applicative f) => k a -> a -> DMap k f -> DMap k f
(~=>) k v = dmat k ?~ pure v

updateInnerSetting
  :: ( Applicative g
     , Applicative f
     , DM.GCompare k1
     , DM.GCompare k2
     )
  => k1 (DMap k2 f)
  -> k2 a
  -> a
  -> (a -> a)
  -> DMap k1 g
  -> DMap k1 g
updateInnerSetting outerKey innerKey opt f dm0 = dm0 & dmat outerKey %~ Just . maybe
  (pure $ DM.singleton innerKey (pure opt))
  (fmap (dmat innerKey %~ Just . maybe (pure opt) (fmap f)))

dmatKey
  :: ( GCompare k
     , Monad g
     , Applicative f
     )
  => (k a -> Text)
  -> k a
  -> D.Decoder g a
  -> D.Decoder g (DMap k f)
dmatKey toText k d = D.atKeyOptional (toText k) d <&> \case
  Nothing -> DM.empty
  Just v  -> DM.singleton k (pure v)

decodeDMap
  :: ( GCompare k
     , Monad f
     , Functor g
     )
  => [D.Decoder f (DMap k g)]
  -> D.Decoder f (DMap k g)
decodeDMap =
  fmap DM.unions . sequenceA

encodeDMap
  :: Applicative f
  => (forall v. k v -> (Text, E.Encoder' v))
  -> E.Encoder f (DMap k Identity)
encodeDMap objBits = E.mapLikeObj $ \dm obj -> DM.foldrWithKey
  (\k v -> case objBits k of (key, enc) -> E.atKey' key enc $ runIdentity v) obj dm

instance JsonEncode WDJson a => JsonEncode WDJson (Vector a) where
  mkEncoder = E.traversable <$> mkEncoder

instance JsonDecode WDJson a => JsonDecode WDJson (Vector a) where
  mkDecoder = D.withCursor . D.rightwardSnoc V.empty <$> mkDecoder

-- | This package tries to be a faithful implementation of the W3C
-- WebDriver Specification, as such the types and their names will be the
-- same or as near as possible to the specification.
newtype Success a = Success { getSuccessValue :: a }
  deriving (Show, Eq, Functor)

instance JsonDecode WDJson () where
  mkDecoder = pure D.null

instance JsonDecode WDJson a => JsonDecode WDJson (Success a) where
  mkDecoder = pure $ Success <$> D.atKey "value" (untag $ mkDecoder @WDJson)

newtype Base64 = Base64
  { unBase64 :: ByteString }
  deriving (Show, Eq)

decBase64 :: Monad f => D.Decoder f Base64
decBase64 = withString $ bimap (mappend "Base64 : " . T.pack) Base64 . B64.decode . B8.pack

encBase64 :: Applicative f => E.Encoder f Base64
encBase64 = B8.unpack . B64.encode . unBase64 >$< E.string

instance JsonDecode WDJson Base64 where mkDecoder = pure decBase64
instance JsonEncode WDJson Base64 where mkEncoder = pure encBase64
