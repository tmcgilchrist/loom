{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Loom.Fetch.HTTPS (
    HTTPSError (..)
  , renderHTTPSError
  , httpsFetcher
  , httpsFetch
  , RedirectPolicy (..)
  , redirectOk
  , tlsTldRedirectPolicy
  ) where


import           Control.Monad.IO.Class (MonadIO (..))

import           Data.ByteString (ByteString)
import qualified Data.ByteString as SB
import qualified Data.ByteString.Char8 as B8
import qualified Data.ByteString.Lazy as LB
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

import qualified Network.HTTP.Client as HTTPS
import qualified Network.HTTP.Client.TLS as HTTPS
import qualified Network.HTTP.Types as HTTPS

import           Loom.Core.Data (Uri (..))
import           Loom.Fetch.Data

import           P

import           System.Directory (createDirectoryIfMissing)
import           System.IO (IO, FilePath)
import qualified System.IO as IO
import           System.IO.Temp (openTempFile)

import           X.Control.Monad.Trans.Either (EitherT, hoistEither, left, runEitherT)


data HTTPSError =
    BadResponseCode Int ByteString
  | BadUri Uri
  | RedirectNoLocation
  | RedirectTooMany
  | RedirectBadPort Int Int
  | RedirectBadHost ByteString
  | RedirectBadTLS Bool Bool
  deriving (Eq, Ord, Show)

renderHTTPSError :: HTTPSError -> Text
renderHTTPSError he =
  "[HTTPS] " <>
    case he of
      BadResponseCode x msg ->
        "Unexpected response: " <> renderIntegral x <> " " <> TE.decodeUtf8 msg
      BadUri (Uri uri) ->
        "Invalid URI: " <> T.pack uri
      RedirectNoLocation ->
        "Invalid redirect: no location"
      RedirectTooMany ->
        "Exceeded redirect count"
      RedirectBadPort want have ->
        "Invalid redirect: expected port " <> renderIntegral want <> ", got " <> renderIntegral have
      RedirectBadHost host ->
        "Invalid redirect: rejected host " <> TE.decodeUtf8 host
      RedirectBadTLS True _ ->
        "Invalid redirect: expected TLS"
      RedirectBadTLS False _ ->
        "Invalid redirect: unexpected TLS"

data RedirectPolicy = RedirectPolicy {
    redirectCount :: !Int
  , redirectPort :: !Int
  , redirectSecure :: !Bool
  , redirectHostPred :: (ByteString -> Bool)
  }

redirectOk :: RedirectPolicy -> HTTPS.Request -> Either HTTPSError RedirectPolicy
redirectOk (RedirectPolicy cnt port tls hostf) req = do
  unless (cnt > 0) (Left RedirectTooMany)
  unless (port == HTTPS.port req) (Left (RedirectBadPort port (HTTPS.port req)))
  unless (tls == HTTPS.secure req) (Left (RedirectBadTLS tls (HTTPS.secure req)))
  unless (hostf (HTTPS.host req)) (Left (RedirectBadHost (HTTPS.host req)))
  pure (RedirectPolicy (cnt-1) port tls hostf)

-- | A fairly strict redirect policy, requiring the hostname of any
-- redirect to retain the original host as a suffix. It also requires
-- TLS over 443, with a low redirect count.
tlsTldRedirectPolicy :: ByteString -> RedirectPolicy
tlsTldRedirectPolicy host =
  RedirectPolicy {
      redirectCount = 3
    , redirectPort = 443
    , redirectSecure = True
    , redirectHostPred = SB.isSuffixOf host
    }

httpsFetcher :: FilePath -> (a -> Uri) -> RedirectPolicy -> IO (Fetcher a HTTPSError FilePath)
httpsFetcher tmpdir f rp = do
  mgr <- HTTPS.newTlsManager
  createDirectoryIfMissing True tmpdir
  pure . Fetcher $ \a -> do
    let uri = f a
    req <- maybe (left (BadUri uri)) pure (HTTPS.parseRequest (unUri uri))
    (fp, h) <- liftIO (openTempFile tmpdir "loom-")
    lbs <- fmap HTTPS.responseBody (httpsFetch mgr rp req {
        -- Force TLS, regardless of the provided URI
        HTTPS.secure = True
      })
    liftIO (LB.hPut h lbs)
    liftIO (IO.hClose h)
    pure fp

httpsFetch ::
     HTTPS.Manager
  -> RedirectPolicy
  -> HTTPS.Request
  -> EitherT HTTPSError IO (HTTPS.Response LB.ByteString)
httpsFetch mgr rp req = do
  e <- liftIO . HTTPS.withResponse req {
    -- Throw no exceptions on bad response code
      HTTPS.checkResponse = (\_ _ -> pure ())
    -- Never follow redirects - should always be done by the consumer explicitly if appropriate
    , HTTPS.redirectCount = 0
    } mgr $ \res ->
      case HTTPS.responseStatus res of
        HTTPS.Status 302 _ -> do
          either
            (pure . Left)
            (runEitherT . uncurry (httpsFetch mgr))
            (do let hdrs = HTTPS.responseHeaders res
                req' <- maybe (Left RedirectNoLocation) pure $ do
                  (_, loc) <- find ((== "Location") . fst) hdrs
                  HTTPS.parseRequest (B8.unpack loc)
                rp' <- redirectOk rp req'
                pure (rp', req'))
        HTTPS.Status 200 _ -> do
          bss <- HTTPS.brConsume $ HTTPS.responseBody res
          pure (Right res { HTTPS.responseBody = LB.fromChunks bss })
        HTTPS.Status x msg ->
          pure (Left (BadResponseCode x msg))
  hoistEither e