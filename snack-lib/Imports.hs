{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MagicHash #-}

import Control.Monad.IO.Class
import Data.Semigroup
import System.Environment
import qualified DriverPipeline
import DynFlags
import qualified FastString
import GHC
import ErrUtils
import Bag
import qualified GHC.IO.Handle.Text as Handle
import qualified HsImpExp
import qualified HsSyn
import HscTypes
import Control.Exception
import qualified Lexer
import qualified Module
import qualified Outputable
import qualified Parser
import qualified SrcLoc
import qualified StringBuffer
import qualified System.Process as Process
import System.IO (stderr)
import GHC.LanguageExtensions.Type

alterSettings :: (Settings -> Settings) -> DynFlags -> DynFlags
alterSettings f dflags = dflags { settings = f (settings dflags) }

main :: IO ()
main = do
    -- Read the output of @--print-libdir@ for 'runGhc'
    (_,Just ho1, _, hdl) <- Process.createProcess
      (Process.shell "ghc --print-libdir"){Process.std_out=Process.CreatePipe}
    libdir <- filter (/= '\n') <$> Handle.hGetContents ho1
    _ <- Process.waitForProcess hdl

    args <- getArgs

    -- Some gymnastics to make the parser happy
    res <- GHC.runGhc (Just libdir)
      $ do
        dflags <- GHC.getSessionDynFlags

        (dflags2, leftovers, warns) <- parseDynamicFlagsCmdLine dflags (map (mkGeneralLocated "on the commandline") args)
        liftIO $ HscTypes.handleFlagWarnings dflags warns

        fp <- case (map unLoc leftovers) of
          [fp] -> pure fp
          [] -> fail "Please provide exactly one argument (got none)"
          xs -> fail $ "Please provide exactly one argument, got: \n" <> unlines xs


        GHC.setSessionDynFlags dflags2
        -- GHC.setSession hsc_env { HscTypes.hsc_dflags = dflag_verbose }
        hsc_env <- GHC.getSession
        -- XXX: We need to preprocess the file so that all extensions are
        -- loaded
        (dflags, newfp) <- liftIO $ DriverPipeline.preprocess hsc_env (fp, Nothing)
        GHC.setSession hsc_env { HscTypes.hsc_dflags = dflags }

        -- Read the file that we want to parse
        str <- liftIO $ readFile newfp

        runParser newfp str (Parser.parseModule) >>= \case
          Lexer.POk _ (SrcLoc.L _ res) -> pure res
          Lexer.PFailed _ span e -> liftIO $ do
            Handle.hPutStrLn stderr $ unlines
              [ "Could not parse module: "
              , newfp
              , " because " <> Outputable.showSDocUnsafe e
              , " src span "
              , show span
              ]
            throwIO $ mkSrcErr (unitBag $ mkPlainErrMsg dflags span e)

    -- Extract the imports from the parsed module
    let imports' =
          map (\(SrcLoc.L _ idecl) ->
                  let SrcLoc.L _ n = HsImpExp.ideclName idecl
                  in Module.moduleNameString n) (HsSyn.hsmodImports res)

    -- here we pretend that @show :: [String] -> String@ outputs JSON
    print imports'

runParser :: FilePath -> String -> Lexer.P a -> GHC.Ghc (Lexer.ParseResult a)
runParser filename str parser = do
    dynFlags <- DynFlags.getDynFlags
    pure $ Lexer.unP parser (parseState dynFlags)
  where
    location = SrcLoc.mkRealSrcLoc (FastString.mkFastString filename) 1 1
    buffer = StringBuffer.stringToStringBuffer str
    parseState flags = Lexer.mkPState flags buffer location
