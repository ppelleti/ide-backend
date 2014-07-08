-- | Client interface to the `ide-backend-server` process
--
-- It is important that none of the types here rely on the GHC library.
{-# LANGUAGE TemplateHaskell, ScopedTypeVariables, TupleSections #-}
module IdeSession.GHC.Client (
    -- * Starting and stopping the server
    InProcess
  , GhcServer(..)
  , forkGhcServer
  , shutdownGhcServer
  , forceShutdownGhcServer
  , getGhcExitCode
    -- * Interacting with the server
  , RunActions(..)
  , runWaitAll
  , rpcCompile
  , rpcRun
  , rpcCrash
  , rpcSetEnv
  , rpcSetArgs
  , rpcBreakpoint
  , rpcPrint
  , rpcLoad
  , rpcSetGhcOpts
  ) where

import Control.Applicative ((<$>))
import Control.Concurrent (killThread)
import Control.Concurrent.Async (async, cancel, withAsync)
import Control.Concurrent.Chan (Chan, newChan, writeChan)
import Control.Concurrent.MVar (newMVar)
import Control.Monad (when, forever)
import Data.Typeable (Typeable)
import Data.Binary (Binary)
import System.Exit (ExitCode)
import System.Posix.Signals (sigKILL, signalProcess)
import qualified Control.Exception as Ex
import qualified Data.ByteString.Char8      as BSS
import qualified Data.ByteString.Lazy.Char8 as BSL

import IdeSession.Config
import IdeSession.GHC.API
import IdeSession.RPC.Client
import IdeSession.State
import IdeSession.Types.Private (RunResult(..))
import IdeSession.Types.Progress
import IdeSession.Util
import IdeSession.Util.BlockingOps
import qualified IdeSession.Types.Public as Public

import Distribution.Verbosity (normal)
import Distribution.Simple (PackageDB(..), PackageDBStack)
import Distribution.Simple.Program.Find ( -- From our patched cabal
    ProgramSearchPath
  , findProgramOnSearchPath
  , ProgramSearchPathEntry(..)
  )

{------------------------------------------------------------------------------
  Starting and stopping the server
------------------------------------------------------------------------------}

-- | Start the ghc server
forkGhcServer :: IdeStaticInfo -> IO (Either ExternalException (GhcServer, GhcVersion))
forkGhcServer IdeStaticInfo{ideConfig, ideSessionDir} = do
  when configInProcess $
    fail "In-process ghc server not currently supported"

  mLoc <- findProgramOnSearchPath normal searchPath "ide-backend-server"
  case mLoc of
    Nothing ->
      fail $ "Could not find ide-backend-server"
    Just prog -> do
      env     <- envWithPathOverride configExtraPathDirs
      server  <- OutProcess <$> forkRpcServer prog [] (Just (ideSessionDataDir ideSessionDir)) env
      version <- Ex.try $ do
        GhcInitResponse{..} <- rpcInit server GhcInitRequest {
            ghcInitClientApiVersion   = ideBackendApiVersion
          , ghcInitGenerateModInfo    = configGenerateModInfo
          , ghcInitOpts               = opts
          , ghcInitUserPackageDB      = userDB
          , ghcInitSpecificPackageDBs = specificDBs
          , ghcInitSessionDir         = ideSessionDir
          }
        return ghcInitVersion
      return ((server,) <$> version)
  where
    (userDB, specificDBs) = splitPackageDBStack configPackageDBStack

    opts :: [String]
    opts = "-XHaskell2010"  -- see #190
           : configStaticOpts
           ++ relInclToOpts (ideSessionSourceDir ideSessionDir) configRelativeIncludes

    searchPath :: ProgramSearchPath
    searchPath = map ProgramSearchPathDir configExtraPathDirs
              ++ [ProgramSearchPathDefault]

    SessionConfig{..} = ideConfig

{- TODO: Reenable in-process
forkGhcServer configGenerateModInfo opts workingDir True = do
  let conv a b = RpcConversation {
                   get = do bs <- $readChan a
                            case decode' bs of
                              Just x  -> return x
                              Nothing -> fail "JSON failure"
                 , put = writeChan b . encode
                 }
  a   <- newChan
  b   <- newChan
  tid <- forkIO $ ghcServerEngine configGenerateModInfo opts (conv a b)
  return $ InProcess (conv b a) tid
-}

splitPackageDBStack :: PackageDBStack -> (Bool, [String])
splitPackageDBStack dbstack = case dbstack of
  (GlobalPackageDB:UserPackageDB:dbs) -> (True,  map specific dbs)
  (GlobalPackageDB:dbs)               -> (False, map specific dbs)
  _                                   -> ierror
  where
    specific (SpecificPackageDB db) = db
    specific _                      = ierror

    ierror :: a
    ierror = error $ "internal error: unexpected package db stack: "
                  ++ show dbstack

shutdownGhcServer :: GhcServer -> IO ()
shutdownGhcServer (OutProcess server) = shutdown server
shutdownGhcServer (InProcess _ tid)   = killThread tid

forceShutdownGhcServer :: GhcServer -> IO ()
forceShutdownGhcServer (OutProcess server) = forceShutdown server
forceShutdownGhcServer (InProcess _ tid)   = killThread tid

getGhcExitCode :: GhcServer -> IO (Maybe ExitCode)
getGhcExitCode (OutProcess server) =
  getRpcExitCode server
getGhcExitCode (InProcess _ _) =
  fail "getGhcExitCode not supported for in-process server"

{------------------------------------------------------------------------------
  Interacting with the server
------------------------------------------------------------------------------}

-- | Repeatedly call 'runWait' until we receive a 'Right' result, while
-- collecting all 'Left' results
runWaitAll :: forall a. RunActions a -> IO (BSL.ByteString, a)
runWaitAll RunActions{runWait} = go []
  where
    go :: [BSS.ByteString] -> IO (BSL.ByteString, a)
    go acc = do
      resp <- runWait
      case resp of
        Left  bs        -> go (bs : acc)
        Right runResult -> return (BSL.fromChunks (reverse acc), runResult)

-- | Set the environment
rpcSetEnv :: GhcServer -> [(String, Maybe String)] -> IO ()
rpcSetEnv (OutProcess server) env = rpc server (ReqSetEnv env)
rpcSetEnv (InProcess _ _)     env = setupEnv env

-- | Set command line arguments
rpcSetArgs :: GhcServer -> [String] -> IO ()
rpcSetArgs (OutProcess server) args =
  rpc server (ReqSetArgs args)
rpcSetArgs (InProcess _ _) _ =
  error "rpcSetArgs not supported for in-process server"

-- | Set ghc options
rpcSetGhcOpts :: GhcServer -> [String] -> IO ([String], [String])
rpcSetGhcOpts (OutProcess server) opts =
  rpc server (ReqSetGhcOpts opts)
rpcSetGhcOpts (InProcess _ _) _ =
  error "rpcSetGhcOpts not supported for in-process server"

-- | Compile or typecheck
rpcCompile :: GhcServer           -- ^ GHC server
           -> Bool                -- ^ Should we generate code?
           -> Public.Targets      -- ^ Targets
           -> (Progress -> IO ()) -- ^ Progress callback
           -> IO GhcCompileResult
rpcCompile server genCode targets callback =
  ghcConversation server $ \RpcConversation{..} -> do
    put (ReqCompile genCode targets)

    let go = do response <- get
                case response of
                  GhcCompileProgress pcounter -> callback pcounter >> go
                  GhcCompileDone result       -> return result

    go

-- | Set breakpoint
--
-- Returns @Just@ the old value of the break if successful, or @Nothing@ if
-- the breakpoint could not be found.
rpcBreakpoint :: GhcServer
              -> Public.ModuleName -> Public.SourceSpan
              -> Bool
              -> IO (Maybe Bool)
rpcBreakpoint server reqBreakpointModule reqBreakpointSpan reqBreakpointValue =
  ghcRpc server ReqBreakpoint{..}

data SnippetAction a =
       SnippetOutput BSS.ByteString
     | SnippetTerminated a
     | SnippetForceTerminated a

-- | Run code
rpcRun :: forall a.
          GhcServer                 -- ^ GHC server
       -> RunCmd                    -- ^ Run command
       -> (Maybe RunResult -> IO a) -- ^ Translate run results
                                    -- @Nothing@ indicates force cancellation
       -> IO (RunActions a)
rpcRun server cmd translateResult = do
  runWaitChan <- newChan :: IO (Chan (SnippetAction a))
  reqChan     <- newChan :: IO (Chan GhcRunRequest)

  -- Communicate with the snippet using an independent, concurrent, conversation
  (pid, server') <- do
    (pid, stdin, stdout, stderr) <- ghcRpc server (ReqRun cmd)
    server' <- OutProcess <$> connectToRpcServer stdin stdout stderr
    return (pid, server')

  respThread <- async . Ex.handle (handleExternalException runWaitChan) $ do
    ghcConversation server' $ \RpcConversation{..} -> do
      -- This "respThread" is responsible for reading responses from the RPC
      -- conversation, and writing them to the runWaitChan channel. This thread
      -- terminates when the server replies with GhcRunDone.
      --
      -- In addition, we spawns a second "reqThread" which is responsible for
      -- reading requests from the reqChan and sending them to to server. We
      -- use withAsync so that when then we (the respThread) terminate the
      -- reqThread automatically gets cancelled.
      --
      -- If an exception happens in the respThread it will be written to the
      -- runWaitChan and the snippet will be considered terminated.
      --
      -- (TODO: What happens when an exception happens in the reqThread?)
      withAsync (sendRequests put reqChan) $ \_reqThread -> do
        let go = do resp <- get
                    case resp of
                      GhcRunDone result -> do
                        result' <- translateResult (Just result)
                        writeChan runWaitChan (SnippetTerminated result')
                      GhcRunOutp bs -> do
                        writeChan runWaitChan (SnippetOutput bs)
                        go
        go

  -- The runActionState holds 'Just' the result of the snippet, or 'Nothing' if
  -- it has not yet terminated.  initially is the termination callback to be
  -- called
  runActionsState <- newMVar Nothing

  return RunActions {
      runWait =
        $modifyMVar runActionsState $ \st ->
          case st of
            Just outcome ->
              return (Just outcome, Right outcome)
            Nothing -> do
              outcome <- $readChan runWaitChan
              case outcome of
                SnippetOutput bs ->
                  return (Nothing, Left bs)
                SnippetForceTerminated res -> do
                  return (Just res, Right res)
                SnippetTerminated res -> do
                  return (Just res, Right res)
    , interrupt   = writeChan reqChan GhcRunInterrupt
    , supplyStdin = writeChan reqChan . GhcRunInput
    , forceCancel = do
        signalProcess sigKILL pid
        result <- translateResult Nothing
        writeChan runWaitChan (SnippetForceTerminated result)
        cancel respThread
    }
  where
    sendRequests :: (GhcRunRequest -> IO ()) -> Chan GhcRunRequest -> IO ()
    sendRequests put reqChan = forever $ put =<< $readChan reqChan

    -- TODO: should we restart the session when ghc crashes?
    -- Maybe recommend that the session is started on GhcExceptions?
    handleExternalException :: Chan (SnippetAction a)
                            -> ExternalException
                            -> IO ()
    handleExternalException ch e = do
      result <- translateResult . Just . RunGhcException . show $ e
      writeChan ch $ SnippetTerminated result

-- | Print a variable
rpcPrint :: GhcServer -> Public.Name -> Bool -> Bool -> IO Public.VariableEnv
rpcPrint server var bind forceEval = ghcRpc server (ReqPrint var bind forceEval)

-- | Load an object file
rpcLoad :: GhcServer -> FilePath -> Bool -> IO ()
rpcLoad server path unload = ghcRpc server (ReqLoad path unload)

-- | Crash the GHC server (for debugging purposes)
rpcCrash :: GhcServer -> Maybe Int -> IO ()
rpcCrash server delay = ghcConversation server $ \RpcConversation{..} ->
  put (ReqCrash delay)

-- | Handshake with the server
rpcInit :: GhcServer -> GhcInitRequest -> IO GhcInitResponse
rpcInit = ghcRpc

{------------------------------------------------------------------------------
  Internal
------------------------------------------------------------------------------}

ghcConversation :: GhcServer -> (RpcConversation -> IO a) -> IO a
ghcConversation (OutProcess server) = rpcConversation server
ghcConversation (InProcess conv _)  = ($ conv)

ghcRpc :: (Typeable req, Typeable resp, Binary req, Binary resp)
       => GhcServer -> req -> IO resp
ghcRpc (OutProcess server) = rpc server
ghcRpc (InProcess _ _)     = error "ghcRpc not implemented for in-process server"
