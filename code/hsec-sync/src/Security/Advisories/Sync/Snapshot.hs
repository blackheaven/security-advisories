{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}

-- |
--
-- Helpers for deriving advisory metadata from a Snapshot s.
module Security.Advisories.Sync.Snapshot
  ( SnapshotDirectoryInfo (..),
    SnapshotError (..),
    explainSnapshotError,
    SnapshotUrl (..),
    SnapshotRepositoryEnsuredStatus (..),
    ensureSnapshot,
    getDirectorySnapshotInfo,
    overwriteSnapshot,
    SnapshotRepositoryStatus (..),
    snapshotRepositoryStatus,
  )
where

import qualified Codec.Archive.Tar as Tar
import qualified Codec.Compression.GZip as GZip
import Control.Exception (Exception (displayException), IOException, try)
import Control.Lens
import Control.Monad.Extra (unlessM, whenM)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT, runExceptT, throwE, withExceptT)
import Data.Aeson (FromJSON, eitherDecodeFileStrict)
import qualified Data.ByteString.Lazy as BL
import Data.Either.Combinators (whenLeft)
import Data.Time (UTCTime)
import GHC.Generics (Generic)
import Network.HTTP.Client (HttpException (..), HttpExceptionContent (..))
import Network.Wreq
import qualified System.Directory as D
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

data SnapshotError
  = SnapshotDirectoryMissingE
  | SnapshotIncoherent String
  | SnapshotProcessError SnapshotProcessError

data SnapshotProcessError
  = FetchSnapshotArchive String
  | DirectorySetupSnapshotArchive IOException
  | ExtractSnapshotArchive IOException

explainSnapshotError :: SnapshotError -> String
explainSnapshotError =
  \case
    SnapshotDirectoryMissingE -> "Snapshot directory is missing"
    SnapshotIncoherent e -> "Snapshot directory is incoherent: " <> e
    SnapshotProcessError e ->
      unlines
        [ "An exception occurred during snapshot processing:",
          case e of
            FetchSnapshotArchive x -> "Fetching failed with: " <> show x
            DirectorySetupSnapshotArchive x -> "Directory setup got an exception: " <> show x
            ExtractSnapshotArchive x -> "Extraction got an exception: " <> displayException x
        ]

newtype SnapshotUrl = SnapshotUrl {getSnapshotUrl :: String}

data SnapshotRepositoryStatus
  = SnapshotDirectoryMissing
  | SnapshotDirectoryInitialized
  | SnapshotDirectoryIncoherent

snapshotRepositoryStatus :: FilePath -> IO SnapshotRepositoryStatus
snapshotRepositoryStatus root = do
  dirExists <- D.doesDirectoryExist root
  if dirExists
    then do
      dirAdvisoriesExists <- D.doesDirectoryExist $ root </> "advisories"
      fileMetadataExists <- D.doesFileExist $ root </> "snapshot.json"
      return $
        if dirAdvisoriesExists && fileMetadataExists
          then SnapshotDirectoryInitialized
          else SnapshotDirectoryIncoherent
    else return SnapshotDirectoryMissing

data SnapshotRepositoryEnsuredStatus
  = SnapshotRepositoryCreated
  | SnapshotRepositoryExisting

ensureSnapshot ::
  FilePath ->
  SnapshotUrl ->
  SnapshotRepositoryStatus ->
  ExceptT SnapshotError IO SnapshotRepositoryEnsuredStatus
ensureSnapshot root url =
  \case
    SnapshotDirectoryMissing -> do
      overwriteSnapshot root url
      return SnapshotRepositoryCreated
    SnapshotDirectoryIncoherent -> do
      overwriteSnapshot root url
      return SnapshotRepositoryCreated
    SnapshotDirectoryInitialized ->
      return SnapshotRepositoryExisting

overwriteSnapshot :: FilePath -> SnapshotUrl -> ExceptT SnapshotError IO ()
overwriteSnapshot root url =
  withExceptT SnapshotProcessError $ do
    ensuringPerformed <- liftIO $ try $ ensureEmptyRoot root
    whenLeft ensuringPerformed $
      throwE . DirectorySetupSnapshotArchive

    resultE <- liftIO $ try $ get $ getSnapshotUrl url
    case resultE of
      Left e ->
        throwE $
          FetchSnapshotArchive $
            case e of
              InvalidUrlException url' reason ->
                "Invalid URL " <> show url' <> ": " <> show reason
              HttpExceptionRequest _ content ->
                case content of
                  StatusCodeException response body ->
                    "Request failed with " <> show (response ^. responseStatus) <> ": " <> show body
                  _ ->
                    "Request failed: " <> show content
      Right result -> do
        performed <-
          liftIO $
            try $
              withSystemTempDirectory "security-advisories" $ \tempDir -> do
                let archivePath = tempDir <> "/snapshot-export.tar.gz"
                BL.writeFile archivePath $ result ^. responseBody
                contents <- BL.readFile archivePath
                Tar.unpack root $ Tar.read $ GZip.decompress contents
        whenLeft performed $
          throwE . ExtractSnapshotArchive

ensureEmptyRoot :: FilePath -> IO ()
ensureEmptyRoot root = do
  D.createDirectoryIfMissing False root

  whenM (D.doesDirectoryExist $ root </> "advisories") $
    D.removeDirectoryRecursive $
      root </> "advisories"

  whenM (D.doesFileExist $ root </> "snapshot.json") $
    D.removeFile $
      root </> "snapshot.json"

newtype SnapshotDirectoryInfo = SnapshotDirectoryInfo
  { lastModificationCommitDate :: UTCTime
  }

getDirectorySnapshotInfo :: FilePath -> IO (Either SnapshotError SnapshotDirectoryInfo)
getDirectorySnapshotInfo root =
  runExceptT $ do
    let metadataPath = root </> "snapshot.json"
    unlessM (liftIO $ D.doesFileExist metadataPath) $
      throwE SnapshotDirectoryMissingE

    metadataE <- liftIO $ eitherDecodeFileStrict metadataPath
    case metadataE of
      Left e -> throwE $ SnapshotIncoherent $ "Cannot parse " <> show metadataPath <> ": " <> e
      Right metadata -> return $ SnapshotDirectoryInfo $ latestUpdate metadata

newtype SnapshotMetadata = SnapshotMetadata
  { latestUpdate :: UTCTime
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON)
