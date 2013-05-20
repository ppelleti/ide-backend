-- | Session queries
--
-- We have to be very careful in the types in this module. We should not be
-- using internal types (with explicit sharing or types such as StrictMap),
-- except as part of abstract XShared types.
module IdeSession.Query (
    -- * Types
    Query
  , ManagedFiles(..)
    -- * Queries that rely on the static part of the state only
  , getSessionConfig
  , getSourcesDir
  , getDataDir
  , getBuildDir
  , getDocDir
  , getSourceModule
  , getDataFile
  , getAllDataFiles
    -- * Queries that do not rely on computed state
  , getCodeGeneration
  , getEnv
  , getGhcServer
  , getManagedFiles
    -- * Queries that rely on computed state
  , getSourceErrors
  , getLoadedModules
  , getSpanInfo
  , getImports
  , getAutocompletion
    -- * Debugging (internal use only)
  , dumpIdInfo
  ) where

import Prelude hiding (mod, span)
import Data.List (isInfixOf)
import Data.Accessor ((^.), getVal)
import qualified System.FilePath.Find as Find
import qualified Data.ByteString.Lazy as BSL
import qualified Data.ByteString.Char8 as BSSC
import System.FilePath ((</>))
import Control.Monad (forM_)
import qualified Data.Text as Text (unpack)

import IdeSession.Config
import IdeSession.State
import IdeSession.Types.Translation
import IdeSession.Types.Public
import qualified IdeSession.Types.Private as Private
import IdeSession.GHC.Server (GhcServer)
import IdeSession.Strict.Container
import qualified IdeSession.Strict.Map  as StrictMap
import qualified IdeSession.Strict.List as StrictList
import qualified IdeSession.Strict.Trie as StrictTrie
import qualified IdeSession.Strict.IntervalMap as StrictIntervalMap
import IdeSession.Strict.MVar (withMVar)

{------------------------------------------------------------------------------
  Types
------------------------------------------------------------------------------}

-- | The type of queries in a given session state.
--
-- Queries are in IO because they depend on the current state of the session
-- but they promise not to alter the session state (at least not in any visible
-- way; they might update caches, etc.).
--
type Query a = IdeSession -> IO a

-- | The collection of source and data files submitted by the user.
data ManagedFiles = ManagedFiles
  { sourceFiles :: [FilePath]
  , dataFiles   :: [FilePath]
  }

{------------------------------------------------------------------------------
  Queries that rely on the static part of the state only
------------------------------------------------------------------------------}

-- | Recover the fixed config the session was initialized with.
getSessionConfig :: Query SessionConfig
getSessionConfig = staticQuery $ return . ideConfig

-- | Obtain the source files directory for this session.
getSourcesDir :: Query FilePath
getSourcesDir = staticQuery $ return . ideSourcesDir

-- | Obtain the data files directory for this session.
getDataDir :: Query FilePath
getDataDir = staticQuery $ return . ideDataDir

-- | Obtain the directory prefix for executables compiled in this session.
-- Each executable is in a subdirectory with the same name as the file, e.g.:
-- "BUILD_DIR/typecheck-dir/typecheck-dir".
getBuildDir :: Query FilePath
getBuildDir = staticQuery $ return . (</> "build") . ideDistDir

-- | Obtain the directory prefix for documentation built in this session.
getDocDir :: Query FilePath
getDocDir = staticQuery $ return . (</> "doc") . ideDistDir

-- | Read the current value of one of the source modules.
getSourceModule :: FilePath -> Query BSL.ByteString
getSourceModule path = staticQuery $ \IdeStaticInfo{ideSourcesDir} ->
  BSL.readFile $ internalFile ideSourcesDir path

-- | Read the current value of one of the data files.
getDataFile :: FilePath -> Query BSL.ByteString
getDataFile path = staticQuery $ \IdeStaticInfo{ideDataDir} ->
  BSL.readFile $ ideDataDir </> path

-- | Get the list of all data files currently available to the session:
-- both the files copied via an update and files created by user code.
getAllDataFiles :: Query [FilePath]
getAllDataFiles = staticQuery $ \IdeStaticInfo{ideDataDir} ->
  Find.find Find.always
            (Find.fileType Find.==? Find.RegularFile)
            ideDataDir

{------------------------------------------------------------------------------
  Queries that do not rely on computed state
------------------------------------------------------------------------------}

-- | Is code generation currently enabled?
getCodeGeneration :: Query Bool
getCodeGeneration = simpleQuery $ getVal ideGenerateCode

-- | Get all current environment overrides
getEnv :: Query [(String, Maybe String)]
getEnv = simpleQuery $ getVal ideEnv

-- | Get the RPC server used by the session.
getGhcServer :: Query GhcServer
getGhcServer = simpleQuery $ getVal ideGhcServer

-- | Get the collection of files submitted by the user and not deleted yet.
-- The module names are those supplied by the user as the first
-- arguments of the @updateModule@ and @updateModuleFromFile@ calls,
-- as opposed to the compiler internal @module ... end@ module names.
-- Usually the two names are equal, but they needn't be.
getManagedFiles :: Query ManagedFiles
getManagedFiles = simpleQuery $ translate . getVal ideManagedFiles
  where
    translate :: ManagedFilesInternal -> ManagedFiles
    translate files = ManagedFiles {
        sourceFiles = map fst $ _managedSource files
      , dataFiles   = _managedData files
      }

{------------------------------------------------------------------------------
  Queries that rely on computed state
------------------------------------------------------------------------------}

-- | Get any compilation errors or warnings in the current state of the
-- session, meaning errors that GHC reports for the current state of all the
-- source modules.
--
-- Note that in the initial implementation this will only return warnings from
-- the modules that changed in the last update, the intended semantics is that
-- morally it be a pure function of the current state of the files, and so it
-- would return all warnings (as if you did clean and rebuild each time).
--
-- getSourceErrors does internal normalization. This simplifies the life of the
-- client and anyway there shouldn't be that many source errors that it really
-- makes a big difference.
getSourceErrors :: Query [SourceError]
getSourceErrors = computedQuery $ \Computed{..} ->
  toLazyList $ StrictList.map (removeExplicitSharing computedCache) computedErrors

-- | Get the list of correctly compiled modules, as reported by the compiler
getLoadedModules :: Query [ModuleName]
getLoadedModules = computedQuery $ \Computed{..} ->
  toLazyList $ computedLoadedModules

-- | Get information about an identifier at a specific location
getSpanInfo :: Query (ModuleName -> SourceSpan -> [(SourceSpan, SpanInfo)])
getSpanInfo = computedQuery $ \Computed{..} mod span ->
  let mSpan  = introduceExplicitSharing computedCache span
      mIdMap = StrictMap.lookup mod computedSpanInfo
  in case (mSpan, mIdMap) of
    (Just span', Just idMap) ->
      let aux (a, b) = ( removeExplicitSharing computedCache a
                       , removeExplicitSharing computedCache b
                       )
          doms = map aux $ Private.dominators span' idMap
      -- TODO: HACK
      -- As is evident in the "Type information 9' test, ghc is inconsistent
      -- in the spans that it returns for the expansion of quasi-quotes.
      -- For now, however, there are only two possibilities: the span has
      -- nothing to do with a quasi-quote and will therefore be a single
      -- SpanId, or the span is a quasi-quote, and we will have a SpanQQ
      -- *somewhere* in the list.
      -- Once we report span info for subexpressions, however, this is no
      -- longer true, and the ordering of the spaninfo becomes significant.
      -- In that case we will need to ensure that: the order of the dominators
      -- is correct (with larger spans later in the list, and the immediate
      -- dominator first), and that the SpanQQ immediately follows to "top-level"
      -- node in the AST that corresponds to the expansion of the quasi-quote.
      in case filter isQQ doms of
           [qq] -> [qq]
           _    -> doms
    _ ->
      []
  where
    isQQ (_, SpanQQ _) = True
    isQQ _             = False

-- | Get import information
--
-- This information is available even for modules with parse/type errors
getImports :: Query (ModuleName -> Maybe [Import])
getImports = computedQuery $ \Computed{..} mod ->
  fmap (toLazyList . StrictList.map (removeExplicitSharing computedCache)) $
    StrictMap.lookup mod computedImports

-- | Autocompletion
getAutocompletion :: Query (ModuleName -> String -> [IdInfo])
getAutocompletion = computedQuery $ \Computed{..} ->
    autocomplete computedCache computedAutoMap
  where
    autocomplete :: Private.ExplicitSharingCache
                 -> Strict (Map ModuleName) (Strict Trie (Strict [] (XShared IdInfo)))
                 -> ModuleName -> String
                 -> [IdInfo]
    autocomplete cache mapOfTries modName name =
        let name' = BSSC.pack name
            n     = last (BSSC.split '.' name')
        in filter (\idInfo -> name `isInfixOf` idInfoQN idInfo)
             $ concatMap (toLazyList . StrictList.map (removeExplicitSharing cache))
             . StrictTrie.elems
             . StrictTrie.submap n
             $ mapOfTries StrictMap.! modName

{------------------------------------------------------------------------------
  Debugging
------------------------------------------------------------------------------}

-- | Print the id info maps to the stdout (for debugging purposes only)
dumpIdInfo :: IdeSession -> IO ()
dumpIdInfo session = withComputedState session $ \_ Computed{..} ->
  forM_ (StrictMap.toList computedSpanInfo) $ \(mod, idMap) -> do
    putStrLn $ "*** " ++ Text.unpack mod ++ " ***"
    forM_ (StrictIntervalMap.toList (Private.idMapToMap idMap)) $ \(i, idInfo) -> do
      let idInfo' = removeExplicitSharing computedCache idInfo
          (StrictIntervalMap.Interval (_, fromLine, fromCol) (_, toLine, toCol)) = i
      putStrLn $ show (fromLine, fromCol, toLine, toCol)  ++ ": " ++ show idInfo'

{------------------------------------------------------------------------------
  Auxiliary
------------------------------------------------------------------------------}

withIdleState :: IdeSession -> (IdeIdleState -> IO a) -> IO a
withIdleState IdeSession{ideState} f =
  withMVar ideState $ \st ->
    case st of
      IdeSessionIdle      idleState -> f idleState
      IdeSessionRunning _ idleState -> f idleState
      IdeSessionShutdown            -> fail "Session already shut down."

withComputedState :: IdeSession -> (IdeIdleState -> Computed -> IO a) -> IO a
withComputedState session f = withIdleState session $ \idleState ->
  case toLazyMaybe (idleState ^. ideComputed) of
    Just computed -> f idleState computed
    Nothing       -> fail "This session state does not admit queries."

staticQuery :: (IdeStaticInfo -> IO a) -> Query a
staticQuery f = f . ideStaticInfo

simpleQuery :: (IdeIdleState -> a) -> Query a
simpleQuery f session = withIdleState session $ return . f

computedQuery :: (Computed -> a) -> Query a
computedQuery f session = withComputedState session $ const (return . f)
