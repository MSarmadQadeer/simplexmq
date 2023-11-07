{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module Simplex.RemoteControl.Types where

import Crypto.Random (ChaChaDRG)
import qualified Data.Aeson.TH as J
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString (ByteString)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Data.Time.Clock.System (SystemTime, getSystemTime)
import qualified Network.TLS as TLS
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.SNTRUP761.Bindings (KEMPublicKey, KEMSecretKey, sntrup761Keypair)
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers (dropPrefix, sumTypeJSON)
import Simplex.Messaging.Transport.Credentials (genCredentials, tlsCredentials)
import Simplex.Messaging.Util (safeDecodeUtf8)
import Simplex.Messaging.Version (VersionRange, mkVersionRange)
import UnliftIO

data RCErrorType
  = RCEInternal {internalErr :: String}
  | RCEIdentity
  | RCENoLocalAddress
  | RCETLSStartFailed
  | RCEException {exception :: String}
  | RCECtrlAuth
  | RCECtrlNotFound
  | RCECtrlError {ctrlErr :: String}
  | RCEVersion
  | RCEDecrypt
  | RCEBlockSize
  | RCESyntax {syntaxErr :: String}
  deriving (Eq, Show, Exception)

instance StrEncoding RCErrorType where
  strEncode = \case
    RCEInternal err -> "INTERNAL" <> text err
    RCEIdentity -> "IDENTITY"
    RCENoLocalAddress -> "NO_LOCAL_ADDR"
    RCETLSStartFailed -> "CTRL_TLS_START"
    RCEException err -> "EXCEPTION" <> text err
    RCECtrlAuth -> "CTRL_AUTH"
    RCECtrlNotFound -> "CTRL_NOT_FOUND"
    RCECtrlError err -> "CTRL_ERROR" <> text err
    RCEVersion -> "VERSION"
    RCEDecrypt -> "DECRYPT"
    RCEBlockSize -> "BLOCK_SIZE"
    RCESyntax err -> "SYNTAX" <> text err
    where
      text = (" " <>) . encodeUtf8 . T.pack
  strP =
    A.takeTill (== ' ') >>= \case
      "INTERNAL" -> RCEInternal <$> textP
      "IDENTITY" -> pure RCEIdentity
      "NO_LOCAL_ADDR" -> pure RCENoLocalAddress
      "CTRL_TLS_START" -> pure RCETLSStartFailed
      "EXCEPTION" -> RCEException <$> textP
      "CTRL_AUTH" -> pure RCECtrlAuth
      "CTRL_NOT_FOUND" -> pure RCECtrlNotFound
      "CTRL_ERROR" -> RCECtrlError <$> textP
      "VERSION" -> pure RCEVersion
      "DECRYPT" -> pure RCEDecrypt
      "BLOCK_SIZE" -> pure RCEBlockSize
      "SYNTAX" -> RCESyntax <$> textP
      _ -> fail "bad RCErrorType"
    where
      textP = T.unpack . safeDecodeUtf8 <$> (A.space *> A.takeByteString)

-- * Discovery

ipProbeVersionRange :: VersionRange
ipProbeVersionRange = mkVersionRange 1 1

data IpProbe = IpProbe
  { versionRange :: VersionRange,
    randomNonce :: ByteString
  }
  deriving (Show)

instance Encoding IpProbe where
  smpEncode IpProbe {versionRange, randomNonce} = smpEncode (versionRange, 'I', randomNonce)

  smpP = IpProbe <$> (smpP <* "I") *> smpP

-- * Controller

-- | A bunch of keys that should be generated by a controller to start a new remote session and produce invites
data CtrlSessionKeys = CtrlSessionKeys
  { ts :: SystemTime,
    ca :: C.KeyHash,
    credentials :: TLS.Credentials,
    sSigKey :: C.PrivateKeyEd25519,
    dhKey :: C.PrivateKeyX25519,
    kem :: (KEMPublicKey, KEMSecretKey)
  }

newCtrlSessionKeys :: TVar ChaChaDRG -> (C.APrivateSignKey, C.SignedCertificate) -> IO CtrlSessionKeys
newCtrlSessionKeys rng (caKey, caCert) = do
  ts <- getSystemTime
  (_, C.APrivateDhKey C.SX25519 dhKey) <- C.generateDhKeyPair C.SX25519
  (_, C.APrivateSignKey C.SEd25519 sSigKey) <- C.generateSignatureKeyPair C.SEd25519

  let parent = (C.signatureKeyPair caKey, caCert)
  sessionCreds <- genCredentials (Just parent) (0, 24) "Session"
  let (ca, credentials) = tlsCredentials $ sessionCreds :| [parent]
  kem <- sntrup761Keypair rng

  pure CtrlSessionKeys {ts, ca, credentials, sSigKey, dhKey, kem}

data CtrlCryptoHandle = CtrlCryptoHandle

-- TODO

-- * Host

data HostSessionKeys = HostSessionKeys
  { ca :: C.KeyHash
  -- TODO
  }

data HostCryptoHandle = HostCryptoHandle

-- TODO

-- * Utils

type Tasks = TVar [Async ()]

asyncRegistered :: MonadUnliftIO m => Tasks -> m () -> m ()
asyncRegistered tasks action = async action >>= registerAsync tasks

registerAsync :: MonadIO m => Tasks -> Async () -> m ()
registerAsync tasks = atomically . modifyTVar tasks . (:)

cancelTasks :: MonadIO m => Tasks -> m ()
cancelTasks tasks = readTVarIO tasks >>= mapM_ cancel

$(J.deriveJSON (sumTypeJSON $ dropPrefix "RCE") ''RCErrorType)
