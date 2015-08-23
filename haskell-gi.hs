module Main where

#if !MIN_VERSION_base(4,8,0)
import Control.Applicative ((<$>))
import Data.Traversable (traverse)
#endif
import Control.Monad (forM_, when, (>=>))
import Control.Exception (handle)

import Data.Bool (bool)
import Data.List (intercalate)
import Data.Text (unpack)

import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath (splitPath, joinPath)
import System.Console.GetOpt
import System.Exit
import System.IO (hPutStr, hPutStrLn, stderr)
import System.Environment (getArgs)

import qualified Data.Map as M
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified Data.Set as S

import GI.Utils.GError
import Text.Show.Pretty (ppShow)

import GI.API (loadAPI)
import GI.Cabal (cabalConfig, genCabalProject)
import GI.Code (codeToString, genCode, evalCodeGen)
import GI.Config (Config(..))
import GI.CodeGen (genModule)
import GI.Attributes (genAttributes, genAllAttributes)
import GI.OverloadedSignals (genSignalInstances, genOverloadedSignalConnectors)
import GI.Overrides (Overrides, parseOverridesFile, loadFilteredAPI, nsChooseVersion)
import GI.SymbolNaming (ucFirst)
import GI.Internal.Typelib (prependSearchPath)

data Mode = GenerateCode | Dump | Attributes | Signals | Help

data Options = Options {
  optMode :: Mode,
  optOutput :: Maybe String,
  optOverridesFiles :: [String],
  optSearchPaths :: [String],
  optVerbose :: Bool,
  optCabal :: Bool}

defaultOptions = Options {
  optMode = GenerateCode,
  optOutput = Just "GI",
  optOverridesFiles = [],
  optSearchPaths = [],
  optVerbose = False,
  optCabal = True}

parseKeyValue s =
  let (a, '=':b) = break (=='=') s
   in (a, b)

optDescrs :: [OptDescr (Options -> Options)]
optDescrs = [
  Option "h" ["help"] (NoArg $ \opt -> opt { optMode = Help })
    "\tprint this gentle help text",
  Option "a" ["attributes"] (NoArg $ \opt -> opt {optMode = Attributes})
    "generate generic attribute accesors",
  Option "c" ["connectors"] (NoArg $ \opt -> opt {optMode = Signals})
    "generate generic signal connectors",
  Option "d" ["dump"] (NoArg $ \opt -> opt { optMode = Dump })
    "\tdump internal representation",
  Option "n" ["no-cabal"] (NoArg $ \opt -> opt {optCabal = False})
    "\tdo not generate .cabal file",
  Option "o" ["overrides"] (ReqArg
                           (\arg opt -> opt {optOverridesFiles =
                                                 arg : optOverridesFiles opt})
                          "OVERRIDES")
    "specify a file with overrides info",
  Option "O" ["output"] (ReqArg
                         (\arg opt -> opt {optOutput = Just arg}) "DIR")
    "\tset the output directory",
  Option "s" ["search"] (ReqArg
    (\arg opt -> opt { optSearchPaths = arg : optSearchPaths opt }) "PATH")
    "\tprepend a directory to the typelib search path",
  Option "v" ["verbose"] (NoArg $ \opt -> opt { optVerbose = True })
    "\tprint extra info while processing"]

showHelp = concatMap optAsLine optDescrs
  where optAsLine (Option flag (long:_) _ desc) =
          "  -" ++ flag ++ "|--" ++ long ++ "\t" ++ desc ++ "\n"
        optAsLine _ = error "showHelp"

printGError = handle (gerrorMessage >=> putStrLn . unpack)

outputPath :: Options -> IO (String, String) -- modPrefix, dirPrefix
outputPath options =
    case optOutput options of
      Nothing -> return ("", ".")
      Just dir -> do
        createDirectoryIfMissing True dir
        let prefix = intercalate "." (splitPath dir) ++ "."
        return (prefix, dir)

-- Generate all generic accessor functions ("_label", for example).
genGenericAttrs :: Options -> Overrides -> [String] -> IO ()
genGenericAttrs options ovs modules = do
  allAPIs <- (M.toList . M.unions . map M.fromList)
             <$> mapM (loadFilteredAPI (optVerbose options) ovs) modules
  let cfg = Config {modName = Nothing,
                    verbose = optVerbose options,
                    overrides = ovs}
  (modPrefix, dirPrefix) <- outputPath options
  putStrLn $ "\t* Generating " ++ modPrefix ++ "Properties"
  (_, code) <- genCode cfg (genAllAttributes allAPIs modPrefix)
  writeFile (joinPath [dirPrefix, "Properties.hs"]) $ codeToString code

-- Generate generic signal connectors ("Clicked", "Activate", ...)
genGenericConnectors :: Options -> Overrides -> [String] -> IO ()
genGenericConnectors options ovs modules = do
  allAPIs <- (M.toList . M.unions . map M.fromList)
             <$> mapM (loadFilteredAPI (optVerbose options) ovs) modules
  let cfg = Config {modName = Nothing,
                    verbose = optVerbose options,
                    overrides = ovs}
  (modPrefix, dirPrefix) <- outputPath options
  putStrLn $ "\t* Generating " ++ modPrefix ++ "Signals"
  (_, code) <- genCode cfg (genOverloadedSignalConnectors allAPIs modPrefix)
  writeFile (joinPath [dirPrefix, "Signals.hs"]) $ codeToString code

-- Generate the code for the given module, and return the dependencies
-- for this module.
processMod :: Options -> Overrides -> String -> IO ()
processMod options ovs name = do
  apis <- loadFilteredAPI (optVerbose options) ovs name

  let cfg = Config {modName = Just name,
                    verbose = optVerbose options,
                    overrides = ovs}
      nm = ucFirst name

  (modPrefix, dirPrefix) <- outputPath options

  putStrLn $ "\t* Generating " ++ modPrefix ++ nm
  (modDeps, code) <- genCode cfg (genModule name apis modPrefix)
  writeFile (joinPath [dirPrefix, nm ++ ".hs"]) $
             codeToString code

  putStrLn $ "\t\t+ " ++ modPrefix ++ nm ++ "Attributes"
  (attrDeps, attrCode) <- genCode cfg (genAttributes name apis modPrefix modDeps)
  writeFile (joinPath [dirPrefix, nm ++ "Attributes.hs"]) $
            codeToString attrCode

  putStrLn $ "\t\t+ " ++ modPrefix ++ nm ++ "Signals"
  (sigDeps, signalCode) <- genCode cfg (genSignalInstances name apis modPrefix modDeps)
  writeFile (joinPath [dirPrefix, nm ++ "Signals.hs"]) $
            codeToString signalCode

  when (optCabal options) $ do
    let cabal = nm ++ ".cabal"
    fname <- doesFileExist cabal >>=
             bool (return cabal)
                  (putStrLn (cabal ++ " exists, writing "
                             ++ cabal ++ ".new instead") >>
                   return (cabal ++ ".new"))
    putStrLn $ "\t\t+ " ++ fname
    let allDeps = S.toList
                  $ S.delete name -- The module is not a dep of itself
                  $ S.insert "GLib" -- and GLib always is
                  $ S.unions [modDeps, attrDeps, sigDeps]
    (err, cabalCode) <- evalCodeGen cfg (genCabalProject name allDeps modPrefix)
    case err of
      Nothing -> do
               writeFile fname (codeToString cabalCode)
               putStrLn "\t\t+ cabal.config"
               writeFile "cabal.config" cabalConfig
      Just msg -> putStrLn $ "ERROR: could not generate " ++ fname
                  ++ "\nError was: " ++ msg

dump :: Options -> Overrides -> String -> IO ()
dump options ovs name = do
  apis <- loadAPI (optVerbose options) name (M.lookup name (nsChooseVersion ovs))
  mapM_ (putStrLn . ppShow) apis

process :: Options -> [String] -> IO ()
process options names = do
  mapM_ prependSearchPath $ optSearchPaths options
  configs <- traverse TIO.readFile (optOverridesFiles options)
  case parseOverridesFile (concatMap T.lines configs) of
    Left errorMsg -> do
      hPutStr stderr "Error when parsing the config file(s):\n"
      hPutStr stderr (T.unpack errorMsg)
      exitFailure
    Right ovs -> case optMode options of
                   GenerateCode -> forM_ names (processMod options ovs)
                   Attributes -> genGenericAttrs options ovs names
                   Signals -> genGenericConnectors options ovs names
                   Dump -> forM_ names (dump options ovs)
                   Help -> putStr showHelp

foreign import ccall "g_type.h g_type_init"
    g_type_init :: IO ()

main :: IO ()
main = printGError $ do
    g_type_init -- Initialize GLib's type system.
    args <- getArgs
    let (actions, nonOptions, errors) = getOpt RequireOrder optDescrs args
        options  = foldl (.) id actions defaultOptions

    case errors of
        [] -> return ()
        _ -> do
            mapM_ (hPutStr stderr) errors
            exitFailure

    case nonOptions of
      [] -> failWithUsage
      names -> process options names
    where
      failWithUsage = do
        hPutStrLn stderr "usage: haskell-gi [options] module1 [module2 [...]]"
        hPutStr stderr showHelp
        exitFailure
