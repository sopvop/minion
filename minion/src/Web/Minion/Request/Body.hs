module Web.Minion.Request.Body where

import Control.Monad ((>=>))
import Control.Monad.Catch
import Control.Monad.IO.Class (MonadIO (..))
import Control.Monad.IO.Class qualified as IO
import Data.ByteString qualified as Bytes
import Data.ByteString.Lazy qualified as Bytes.Lazy
import Data.List.NonEmpty qualified as Nel
import Data.Text qualified as Text
import Data.Text.Lazy qualified as Text.Lazy
import Data.Text.Lazy.Encoding qualified as Text.Encode.Lazy
import GHC.Base (Type)
import Network.HTTP.Media qualified as Http
import Network.HTTP.Types qualified as Http
import Network.Wai qualified as Wai
import Web.FormUrlEncoded (FromForm)
import Web.FormUrlEncoded qualified as Http
import Web.Minion.Args (WithReq)
import Web.Minion.Introspect qualified as I
import Web.Minion.Media
import Web.Minion.Media.FormUrlEncoded
import Web.Minion.Media.PlainText (PlainText)

import Web.Minion.Request
import Web.Minion.Router

newtype ReqBody (cts :: [Type]) a = ReqBody a

instance IsRequest (ReqBody cts a) where
  type RequestValue (ReqBody cts a) = a
  getRequestValue (ReqBody a) = a

class DecodeBody cts a where
  decodeBody ::
    (MonadIO m, MonadThrow m) =>
    MakeError ->
    -- | Content-Type header value
    Bytes.ByteString ->
    -- | Request body
    IO Bytes.Lazy.ByteString ->
    m (ReqBody cts a)

instance DecodeBody '[] a where
  decodeBody makeError _ _ = throwM $ makeError Http.status415 "Unsupported Content-Type"

instance (ContentType ct, Decode ct a, DecodeBody cts a) => DecodeBody (ct ': cts) a where
  decodeBody makeError contentType body
    | Just _ <- Http.matchAccept (Nel.toList $ media @ct) contentType =
        liftIO body
          >>= either
            (throwM . makeError Http.status400 . mkBody)
            (pure . ReqBody)
            . decode @ct @a
    | otherwise = do
        ReqBody a :: ReqBody cts a <- decodeBody makeError contentType body
        pure $ ReqBody a
    where
      mkBody msg = Text.Encode.Lazy.encodeUtf8 $ "Failed to parse body: " <> Text.Lazy.fromStrict msg

class Decode ct a where
  decode :: Bytes.Lazy.ByteString -> Either Text.Text a

instance Decode PlainText Text.Text where
  decode = Right . Text.Lazy.toStrict . Text.Encode.Lazy.decodeUtf8

instance Decode PlainText Text.Lazy.Text where
  decode = Right . Text.Encode.Lazy.decodeUtf8

instance Decode PlainText String where
  decode = fmap Text.Lazy.unpack . decode @PlainText

instance (FromForm a) => Decode FormUrlEncoded a where
  decode = Http.urlDecodeForm >=> Http.fromForm

{- | Extracts request body with specified Content-Type

@
... '/>' 'reqBody' \@'[PlainText] \@MyRequest
@
-}
reqBody ::
  forall cts r m i ts.
  (I.Introspection i I.Request (ReqBody cts r)) =>
  (IO.MonadIO m, MonadThrow m) =>
  (DecodeBody cts r) =>
  -- | .
  ValueCombinator i (WithReq m (ReqBody cts r)) ts m
reqBody = Request \makeError req -> case lookup Http.hContentType $ Wai.requestHeaders req of
  Nothing -> throwM $ makeError req Http.status415 "Unsupported Content-Type"
  Just ct -> decodeBody @cts @r (makeError req) ct (Wai.lazyRequestBody req)
