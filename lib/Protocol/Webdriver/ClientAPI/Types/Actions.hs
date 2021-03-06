{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeFamilies          #-}
-- | Types for use with the ['performActions'](https://w3c.github.io/webdriver/#perform-actions) command.
--
module Protocol.Webdriver.ClientAPI.Types.Actions where

import           Control.Lens                                 (( # ), (^.))
import           Control.Monad.Except                         (throwError)

import           Data.Functor.Alt                             ((<!>))
import           Data.Functor.Contravariant                   ((>$<))
import           Data.Text                                    (Text)
import           Generics.SOP.TH                              (deriveGeneric)
import           GHC.Word                                     (Word8)
import           Linear.V2                                    (V2 (..), _x, _y)

import qualified Waargonaut.Decode                            as D
import qualified Waargonaut.Decode.Error                      as D
import qualified Waargonaut.Encode                            as E
import           Waargonaut.Generic                           (JsonDecode (..),
                                                               JsonEncode (..))

import           Protocol.Webdriver.ClientAPI.Types.ElementId (ElementId,
                                                               decElementId,
                                                               encElementIdObject)
import           Protocol.Webdriver.ClientAPI.Types.Internal  (WDJson, decodeFromReadUCFirst,
                                                               encodeShowToLower,
                                                               singleValueObj,
                                                               textMatch)

-- | Actions can be associated with specific identifiers. Such as "keyboard", or "finger1" & "finger2".
--
newtype ActionId = ActionId { _unActionId :: Text }
  deriving (Eq, Show)

encodeActionId :: Applicative f => E.Encoder f ActionId
encodeActionId = _unActionId >$< E.text

decodeActionId :: Monad f => D.Decoder f ActionId
decodeActionId = ActionId <$> D.text

instance JsonEncode WDJson ActionId where mkEncoder = pure encodeActionId
instance JsonDecode WDJson ActionId where mkDecoder = pure decodeActionId

-- | Time in milliseconds that the given action will take:
--
-- - How long the key is help down
-- - How long the pointer takes to move a given distance
--
newtype Duration = Duration { _unDuration :: Int }
  deriving (Eq, Show)

encodeDuration :: Applicative f => E.Encoder f Duration
encodeDuration = _unDuration >$< E.int

decodeDuration :: Monad f => D.Decoder f Duration
decodeDuration = Duration <$> D.int

instance JsonEncode WDJson Duration where mkEncoder = pure encodeDuration
instance JsonDecode WDJson Duration where mkDecoder = pure decodeDuration

-- | The number of the mouse button being pressed.
newtype Button = Button { _unButton :: Word8 }
  deriving (Eq, Show)

-- | Convenience functions for the first four mouse buttons
mouse1, mouse2, mouse3, mouse4 :: Button
mouse1 = Button 1
mouse2 = Button 2
mouse3 = Button 3
mouse4 = Button 4

encodeButton :: Applicative f => E.Encoder f Button
encodeButton = _unButton >$< E.integral

decodeButton :: Monad f => D.Decoder f Button
decodeButton = Button <$> D.integral

instance JsonEncode WDJson Button where mkEncoder = pure encodeButton
instance JsonDecode WDJson Button where mkDecoder = pure decodeButton

-- | Where the pointer is moving from.
data PointerOrigin
  = Viewport
  | Pointer
  | Elem ElementId
  deriving (Eq, Show)

encodePointerOrigin :: Applicative f => E.Encoder f PointerOrigin
encodePointerOrigin = E.encodeA $ \case
  Elem eid -> E.runEncoder encElementIdObject eid
  x        -> E.runEncoder encodeShowToLower x

decodePointerOrigin :: Monad f => D.Decoder f PointerOrigin
decodePointerOrigin =
  textMatch "PointerOrigin" "viewport" Viewport <!>
  textMatch "PointerOrigin" "pointer" Pointer <!>
  (Elem <$> decElementId)

instance JsonEncode WDJson PointerOrigin where mkEncoder = pure encodePointerOrigin
instance JsonDecode WDJson PointerOrigin where mkDecoder = pure decodePointerOrigin

data PointerType
  = Mouse
  | Pen
  | Touch
  deriving (Eq, Show, Read)

decodePointerType :: Monad f => D.Decoder f PointerType
decodePointerType = D.atKey "pointerType" (decodeFromReadUCFirst "PointerType")

encodePointerType :: Applicative f => E.Encoder f PointerType
encodePointerType = singleValueObj "pointerType" encodeShowToLower

instance JsonEncode WDJson PointerType where mkEncoder = pure encodePointerType
instance JsonDecode WDJson PointerType where mkDecoder = pure decodePointerType

data ActionType
  = PointerAction
  | KeyAction
  | None
  deriving (Eq, Show)

encodeActionType :: Applicative f => E.Encoder f ActionType
encodeActionType =
  (\case PointerAction -> "pointer"
         KeyAction -> "key"
         None -> "none"
  ) >$< E.text

decodeActionType :: Monad f => D.Decoder f ActionType
decodeActionType =
  tm "pointer" PointerAction <!>
  tm "key" KeyAction <!>
  tm "none" None
  where
    tm = textMatch "ActionType"

instance JsonEncode WDJson ActionType where mkEncoder = pure encodeActionType
instance JsonDecode WDJson ActionType where mkDecoder = pure decodeActionType

-- | The granular component of an action being performed.
data ActionObject
  = Pause Duration
  | PointerUp Button
  | PointerDown Button
  | PointerMove Duration PointerOrigin (V2 Int)
  | KeyUp Char
  | KeyDown Char
  -- PointerCancel -- undefined in the spec
  deriving (Eq, Show)

encodeActionObject :: Applicative f => E.Encoder f ActionObject
encodeActionObject = E.mapLikeObj $ \case
  Pause d -> atype "pause" . duration d
  PointerUp b -> atype "pointerUp" . button b
  PointerDown b -> atype "pointerDown" . button b
  PointerMove d po xy ->
    atype "pointerMove" .
    duration d .
    E.atKey' "origin" encodePointerOrigin po .
    E.atKey' "x" E.int (xy ^. _x) .
    E.atKey' "y" E.int (xy ^. _y)
  KeyUp k -> atype "keyUp" . key k
  KeyDown k -> atype "keyDown" . key k
  where
    atype = E.atKey' "type" E.text
    duration = E.atKey' "duration" encodeDuration
    button = E.atKey' "button" encodeButton
    key k = E.atKey' "value" E.string [k]

instance JsonEncode WDJson ActionObject where mkEncoder = pure encodeActionObject

decodeActionObject :: Monad f => D.Decoder f ActionObject
decodeActionObject = D.withCursor $ \c -> D.fromKey "type" D.text c >>= \case
  "pause" -> Pause <$> duration c
  "pointerUp" -> PointerUp <$> button c
  "pointerDown" -> PointerDown <$> button c
  "pointerMove" -> PointerMove <$> duration c <*> D.fromKey "origin" decodePointerOrigin c <*> xy c
  "keyUp" -> KeyUp <$> key c
  "keyDown" -> KeyDown <$> key c
  t -> throwError (D._ConversionFailure # ("Unknown action object type: " <> t))
  where
    key = D.fromKey "value" D.unboundedChar
    button = D.fromKey "button" decodeButton
    duration = D.fromKey "duration" decodeDuration

    xy c0 = V2
      <$> D.fromKey "x" D.int c0
      <*> D.fromKey "y" D.int c0

instance JsonDecode WDJson ActionObject where mkDecoder = pure decodeActionObject

-- | The action in it's entirety, which is made of up smaller individual 'ActionObject's
data Action = Action
  { _actionType       :: ActionType
  , _actionId         :: ActionId
  , _actionParameters :: Maybe PointerType
  , _actionActions    :: [ActionObject]
  }
  deriving (Eq, Show)

encodeAction :: Applicative f => E.Encoder f Action
encodeAction = E.mapLikeObj $ \a ->
  E.atKey' "type" encodeActionType (_actionType a) .
  E.atKey' "id" encodeActionId (_actionId a) .
  E.atOptKey' "parameters" encodePointerType (_actionParameters a) .
  E.atKey' "actions" (E.list encodeActionObject) (_actionActions a)

instance JsonEncode WDJson Action where mkEncoder = pure encodeAction

decodeAction :: Monad f => D.Decoder f Action
decodeAction = Action
  <$> D.atKey "type" decodeActionType
  <*> D.atKey "id" decodeActionId
  <*> D.atKeyOptional "parameters" decodePointerType
  <*> D.atKey "actions" (D.list decodeActionObject)

instance JsonDecode WDJson Action where mkDecoder = pure decodeAction

newtype PerformActions = PerformActions
  { _unPerformActions :: [Action] }
  deriving (Show, Eq)
deriveGeneric ''PerformActions

instance JsonEncode WDJson PerformActions where
  mkEncoder = pure (_unPerformActions >$< singleValueObj "actions" (E.list encodeAction))

instance JsonDecode WDJson PerformActions where
  mkDecoder = pure (PerformActions <$> D.atKey "actions" (D.list decodeAction))
