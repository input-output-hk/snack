{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE MonadFailDesugaring #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}

module Main where

import Control.Applicative
import Control.Monad
import Control.Monad.IO.Class
import Data.Aeson (FromJSON, (.:), (.:?))
import Data.FileEmbed (embedStringFile)
import Data.List (intercalate)
import Data.Semigroup ((<>))
import Data.String.Interpolate
import Shelly (Sh)
import System.Directory (canonicalizePath)
import System.Posix.Process (executeFile)
import UnliftIO.Exception
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Types as Aeson
import qualified Data.ByteString as BS
import qualified Data.Map as Map
import qualified Data.Text as T
import qualified Options.Applicative as Opts
import qualified Shelly as S

---
--- Some config helpers

data ConfigStage
  = ConfigRaw
  | ConfigReady

type family Config (c :: ConfigStage) ty1 ty2 where
  Config 'ConfigRaw ty1 _= ty1
  Config 'ConfigReady _ ty2 = ty2

---
--- Configuration proper

type Mode = Mode_ 'ConfigReady

type ModeRaw = Mode_ 'ConfigRaw

data Mode_ c
  = Standalone (Config c FilePath PackageNix) -- Reads a package.nix file
  | HPack (Config c FilePath PackageYaml) -- Reads a package.yaml

prepareMode :: ModeRaw -> IO Mode
prepareMode = \case
    Standalone fp -> Standalone <$> mkPackageNix fp
    HPack fp -> HPack <$> mkPackageYaml fp

-- | Like a FilePath, but Nix friendly
newtype PackageNix = PackageNix { unPackageNix :: FilePath }

mkPackageNix :: FilePath -> IO PackageNix
mkPackageNix = fmap PackageNix . canonicalizePath

-- | Like a FilePath, but Nix friendly
newtype SnackLib = SnackLib { unSnackLib :: FilePath }

mkSnackLib :: FilePath -> IO SnackLib
mkSnackLib = fmap SnackLib . canonicalizePath

-- | Like a FilePath, but Nix friendly
newtype PackageYaml = PackageYaml { unPackageYaml :: FilePath }

mkPackageYaml :: FilePath -> IO PackageYaml
mkPackageYaml = fmap PackageYaml . canonicalizePath

-- | How to call @nix-build@
newtype NixConfig = NixConfig
  { nixNCores :: Int }

type SnackConfig = SnackConfig_ 'ConfigReady
type SnackConfigRaw = SnackConfig_ 'ConfigRaw

-- | Extra configuration for snack
data SnackConfig_ c = SnackConfig
  { snackLib :: Config c (Maybe FilePath) (Maybe SnackLib)
  , snackNixCfg :: NixConfig
  }

data Command
  = Build
  | Run
  | Ghci

main :: IO ()
main = do
    opts <-
      prepareOptions =<<
        Opts.execParser (Opts.info (parseOptions <**> Opts.helper) mempty)
    runCommand (snackConfig opts) (mode opts) (command opts)

type OptionsRaw = Options_ 'ConfigRaw
type Options = Options_ 'ConfigReady

data Options_ c = Options
  { snackConfig :: SnackConfig_ c
  , mode :: Mode_ c
  , command :: Command
  }

prepareOptions :: OptionsRaw -> IO Options
prepareOptions raw =
    Options <$>
      prepareSnackConfig (snackConfig raw) <*>
      prepareMode (mode raw) <*>
      pure (command raw)

prepareSnackConfig :: SnackConfigRaw -> IO SnackConfig
prepareSnackConfig raw =
    SnackConfig <$>
      (case snackLib raw of
        Nothing -> pure Nothing
        Just fp -> Just <$> mkSnackLib fp
      ) <*>
      pure (snackNixCfg raw)

parseNixConfig :: Opts.Parser NixConfig
parseNixConfig =
    (NixConfig <$>
        Opts.option Opts.auto
        (Opts.long "cores"
        <> Opts.short 'j'
        <> Opts.value 1
        <> Opts.metavar "INT"
        <> Opts.help "How many cores to use during the build")
        )

parseSnackConfig :: Opts.Parser SnackConfigRaw
parseSnackConfig = SnackConfig <$> Opts.optional
    (Opts.strOption
        (Opts.long "lib"
        <> Opts.short 'l'
        <> Opts.metavar "DIR"
        <> Opts.help
          (unwords
            [ "Path to the directory to use as the Nix library"
            , "instead of the default one bundled with the snack executable."
            ]
          )
        )
    ) <*>
    parseNixConfig

parseMode :: Opts.Parser ModeRaw
parseMode =
    (Standalone <$>
        Opts.strOption
        (Opts.long "package-nix"
        <> Opts.short 's'
        <> Opts.value "./package.nix"
        <> Opts.metavar "PATH")
        )
    <|>
    (HPack <$>
        Opts.strOption
        (Opts.long "package-yaml"
        <> Opts.value "./package.yaml"
        <> Opts.short 'p'
        <> Opts.metavar "PATH")
        )

parseOptions :: Opts.Parser OptionsRaw
parseOptions =
    Options <$>
      parseSnackConfig <*>
      parseMode <*>
      parseCommand

newtype ModuleName = ModuleName { unModuleName :: T.Text }
  deriving newtype (Ord, Eq, Aeson.FromJSONKey)
  deriving stock Show

data BuildResult
  = BuiltLibrary LibraryBuild
  | BuiltExecutable ExecutableBuild
  | BuiltMulti MultiBuild
  | BuiltGhci GhciBuild
  deriving Show

instance Aeson.FromJSON BuildResult where
    parseJSON v =
      BuiltLibrary <$> (guardBuildType "library" v)
      <|> BuiltExecutable <$> (guardBuildType "executable" v)
      <|> BuiltMulti <$> (guardBuildType "multi" v)
      <|> BuiltGhci <$> (guardBuildType "ghci" v)
      where
        guardBuildType :: FromJSON a => T.Text -> Aeson.Value -> Aeson.Parser a
        guardBuildType ty = Aeson.withObject "build result" $ \o -> do
          bty <- o .: "build_type"
          guard (bty == ty)
          Aeson.parseJSON =<< o .: "result"

newtype GhciBuild = GhciBuild
  { ghciExePath :: NixPath
  }
    deriving stock Show

instance FromJSON GhciBuild where
  parseJSON = Aeson.withObject "ghci build" $ \o ->
    GhciBuild <$> o .: "ghci_path"

-- The kinds of builds: library, executable, or a mix of both (currently only
-- for HPack)
newtype LibraryBuild = LibraryBuild
  { unLibraryBuild :: Map.Map ModuleName NixPath }
  deriving newtype FromJSON
  deriving stock Show

newtype ExecutableBuild = ExecutableBuild
  { exePath :: NixPath }
  deriving stock Show

instance FromJSON ExecutableBuild where
  parseJSON = Aeson.withObject "executable build" $ \o ->
    ExecutableBuild <$> o .: "exe_path"

data MultiBuild = MultiBuild
  { librayBuild :: Maybe LibraryBuild
  , executableBuilds :: Map.Map T.Text ExecutableBuild
  }
  deriving stock Show

instance Aeson.FromJSON MultiBuild where
  parseJSON = Aeson.withObject "multi build" $ \o ->
    MultiBuild
      <$> o .:? "library"
      <*> o .: "executables"

data NixArg = NixArg
  { argType :: NixArgType
  , argName :: T.Text
  , argValue :: T.Text
  }

data NixArgType
  = ArgStr
  | Arg

newtype NixExpr = NixExpr { unNixExpr :: T.Text }

newtype NixPath = NixPath { unNixPath :: T.Text }
  deriving newtype FromJSON
  deriving stock Show

decodeOrFail :: FromJSON a => BS.ByteString -> Sh a
decodeOrFail bs = case Aeson.decodeStrict' bs of
    Just foo -> pure foo
    Nothing -> throwIO $ userError $ unlines
      [ "could not decode " <> show bs ]

nixBuild :: SnackConfig -> [NixArg] -> NixExpr -> Sh NixPath
nixBuild snackCfg extraNixArgs nixExpr =
    NixPath <$> runStdin1
      (T.pack [i|
        { #{ intercalate "," funArgs } }:
        let
          spec = builtins.fromJSON specJson;
          pkgs = import (builtins.fetchTarball
            { url = "https://github.com/${spec.owner}/${spec.repo}/archive/${spec.rev}.tar.gz";
              sha256 = spec.sha256;
            }) {} ;
          libDir = #{ libDir };
          snack = pkgs.callPackage libDir {};
        in #{ T.unpack $ unNixExpr $ nixExpr }
      |])
      "nix-build"
      cliArgs
  where
    libDir :: String
    libDir = case snackLib snackCfg of
      Just (SnackLib fp) -> fp
      Nothing ->
        [i|
              let
                b64 = pkgs.writeTextFile { name = "lib-b64"; text = lib64; };
              in
                pkgs.runCommand "snack-lib" {}
                ''
                  cat ${b64} | base64 --decode > out.tar.gz
                  mkdir -p $out
                  tar -C $out -xzf out.tar.gz
                  chmod +w $out
                ''
        |]
    cliArgs :: [T.Text]
    cliArgs =
      [ "-" -- read expression from stdin
      , "--no-out-link" -- no need for roots
      -- how many cores to use (-j)
      , "--cores", T.pack (show (nixNCores nixCfg))
      ] <> (concatMap toCliArgs nixArgs)
    funArgs :: [String]
    funArgs = toFunArg <$> nixArgs
    nixArgs :: [NixArg]
    nixArgs =
      [ NixArg { argType = ArgStr , argName = "specJson", argValue = specJson }
      , NixArg { argType = ArgStr , argName = "lib64", argValue = libb64 }
      ] <> extraNixArgs
    toFunArg :: NixArg -> String
    toFunArg = T.unpack . argName
    toCliArgs :: NixArg -> [T.Text]
    toCliArgs narg = case argType narg of
      { Arg -> "--arg"; ArgStr -> "--argstr" }
      : [ argName narg , argValue narg ]
    nixCfg = snackNixCfg snackCfg

snackBuild :: SnackConfig -> PackageNix -> Sh BuildResult
snackBuild snackCfg packageNix = do
    NixPath out <- nixBuild snackCfg
      [ NixArg
          { argName = "packageNix"
          , argValue = T.pack $ unPackageNix packageNix
          , argType = Arg
          }
      ]
      $ NixExpr "snack.inferSnackBuild packageNix"
    decodeOrFail =<< liftIO (BS.readFile $ T.unpack out)

snackGhci :: SnackConfig -> PackageNix -> Sh GhciBuild
snackGhci snackCfg packageNix = do
    NixPath out <- nixBuild snackCfg
      [ NixArg
          { argName = "packageNix"
          , argValue = T.pack $ unPackageNix packageNix
          , argType = Arg
          }
      ]
      $ NixExpr "snack.inferSnackGhci packageNix"
    liftIO (BS.readFile (T.unpack out)) >>= decodeOrFail >>= \case
      BuiltGhci g -> pure g
      b -> throwIO $ userError $ "Expected GHCi build, got " <> show b

snackBuildHPack :: SnackConfig -> PackageYaml -> Sh BuildResult
snackBuildHPack snackCfg packageYaml = do
    NixPath out <- nixBuild snackCfg
      [ NixArg
          { argName = "packageYaml"
          , argValue = T.pack $ unPackageYaml packageYaml
          , argType = Arg
          }
      ]
      $ NixExpr "snack.inferHPackBuild packageYaml"
    decodeOrFail =<< liftIO (BS.readFile (T.unpack out))

snackGhciHPack :: SnackConfig -> PackageYaml -> Sh GhciBuild
snackGhciHPack snackCfg packageYaml = do
    NixPath out <- nixBuild snackCfg
      [ NixArg
          { argName = "packageYaml"
          , argValue = T.pack $ unPackageYaml packageYaml
          , argType = Arg
          }
      ]
      $ NixExpr "snack.inferHPackGhci packageYaml"
    liftIO (BS.readFile (T.unpack out)) >>= decodeOrFail >>= \case
      BuiltGhci g -> pure g
      b -> throwIO $ userError $ "Expected GHCi build, got " <> show b

runCommand :: SnackConfig -> Mode -> Command -> IO ()
runCommand snackCfg (Standalone packageNix) = \case
  Build -> S.shelly $ void $ snackBuild snackCfg packageNix
  Run -> quiet (snackBuild snackCfg packageNix) >>= runBuildResult
  Ghci -> runExe =<< ghciExePath <$> (quiet (snackGhci snackCfg packageNix))
runCommand snackCfg (HPack packageYaml) = \case
  Build -> S.shelly $ void $ snackBuildHPack snackCfg packageYaml
  Run -> quiet (snackBuildHPack snackCfg packageYaml) >>= runBuildResult
  Ghci ->
    runExe =<< ghciExePath <$>  (quiet (snackGhciHPack snackCfg packageYaml))

runBuildResult :: BuildResult -> IO ()
runBuildResult = \case
    BuiltExecutable (ExecutableBuild p) -> runExe p
    BuiltMulti b
      | [ExecutableBuild exe] <- Map.elems (executableBuilds b) -> runExe exe
    b -> fail $ "Unexpected build type: " <> show b

quiet :: Sh a -> IO a
quiet = S.shelly . S.print_stdout False
runExe :: NixPath -> IO ()
runExe (NixPath fp) = executeFile (T.unpack fp) True [] Nothing

parseCommand :: Opts.Parser Command
parseCommand =
  Opts.hsubparser $
    ( Opts.command "build" (Opts.info (pure Build) mempty)
    <>  Opts.command "run" (Opts.info (pure Run) mempty)
    <>  Opts.command "ghci" (Opts.info (pure Ghci) mempty)
    )

run :: S.FilePath -> [T.Text] -> Sh [T.Text]
run p args = T.lines <$> S.run p args

runStdin1 :: T.Text -> S.FilePath -> [T.Text] -> Sh T.Text
runStdin1 stin p args = do
    S.setStdin stin
    run p args >>= \case
      [out] -> pure out
      xs -> throwIO $ userError $ "unexpected output: " <> show xs

run_ :: S.FilePath -> [T.Text] -> Sh ()
run_ p args = void $ run p args

specJson :: T.Text
specJson = $(embedStringFile "spec.json")

libb64 :: T.Text
libb64 = $(embedStringFile "lib.tar.gz.b64")
