{-# LANGUAGE TypeSynonymInstances, FlexibleInstances, ScopedTypeVariables, StandaloneDeriving #-}
{-# OPTIONS_GHC -fno-warn-unused-do-bind -fno-warn-orphans #-}
module GhcShim.GhcShim78
  ( -- * Pretty-printing
    showSDoc
  , pretty
  , prettyM
  , prettyType
  , prettyTypeM
    -- * Errors
  , sourceErrorSpan
    -- * Breakpoints
  , getBreak
  , setBreak
    -- * Time
  , GhcTime
    -- * Setup
  , ghcGetVersion
  , packageDBFlags
  , setGhcOptions
  , storeDynFlags
    -- * Folding
  , AstAlg(..)
  , fold
    -- * Operations on types
  , typeOfTyThing
    -- * Re-exports
  , tidyOpenType
  ) where

import Prelude hiding (id, span)
import Control.Monad (void, forM_, liftM)
import Data.Time (UTCTime)
import Data.IORef
import System.IO.Unsafe (unsafePerformIO)

import Bag
import BasicTypes
import ConLike (ConLike(RealDataCon))
import DataCon (dataConRepType)
import DynFlags
import ErrUtils
import FastString
import GHC hiding (getBreak)
import Linker
import MonadUtils
import Outputable hiding (showSDoc)
import Pair
import PprTyThing
import Pretty
import SrcLoc
import TcEvidence
import TcHsSyn
import TcType
import Type
import TysWiredIn
import qualified BreakArray

import GhcShim.API
import IdeSession.GHC.API (GhcVersion(..))

{------------------------------------------------------------------------------
  Pretty-printing
------------------------------------------------------------------------------}

showSDoc :: DynFlags -> PprStyle -> SDoc -> String
showSDoc dflags pprStyle doc =
    showDoc OneLineMode 100
  $ runSDoc doc
  $ initSDocContext dflags pprStyle

pretty :: Outputable a => DynFlags -> PprStyle -> a -> String
pretty dynFlags pprStyle = showSDoc dynFlags pprStyle . ppr

prettyType :: DynFlags -> PprStyle -> Bool -> Type -> String
prettyType dynFlags pprStyle showForalls typ =
    showSDoc dynFlags' pprStyle (pprTypeForUser typ)
  where
    dynFlags' :: DynFlags
    dynFlags' | showForalls = dynFlags `gopt_set`   Opt_PrintExplicitForalls
              | otherwise   = dynFlags `gopt_unset` Opt_PrintExplicitForalls

prettyM :: (Outputable a, Monad m, HasDynFlags m) => PprStyle -> a -> m String
prettyM pprStyle x = do
  dynFlags <- getDynFlags
  return (pretty dynFlags pprStyle  x)

prettyTypeM :: (Monad m, HasDynFlags m) => PprStyle -> Bool -> Type -> m String
prettyTypeM pprStyle showForalls typ = do
  dynFlags <- getDynFlags
  return $ prettyType dynFlags pprStyle showForalls typ

{------------------------------------------------------------------------------
  Show instances
------------------------------------------------------------------------------}

deriving instance Show Severity

{------------------------------------------------------------------------------
  Source errors
------------------------------------------------------------------------------}

sourceErrorSpan :: ErrMsg -> Maybe SrcSpan
sourceErrorSpan errMsg = case errMsgSpan errMsg of
  real@RealSrcSpan{} -> Just real
  _                  -> Nothing

{------------------------------------------------------------------------------
  Breakpoints
------------------------------------------------------------------------------}

getBreak :: BreakArray -> Int -> Ghc (Maybe Bool)
getBreak array index = do
  dflags <- getDynFlags
  val    <- liftIO $ BreakArray.getBreak dflags array index
  return ((== 1) `liftM` val)

setBreak :: BreakArray -> Int -> Bool -> Ghc ()
setBreak array index value = do
  dflags <- getDynFlags
  void . liftIO $ if value then BreakArray.setBreakOn  dflags array index
                           else BreakArray.setBreakOff dflags array index

{------------------------------------------------------------------------------
  Time
------------------------------------------------------------------------------}

type GhcTime = UTCTime

{------------------------------------------------------------------------------
  Setup
------------------------------------------------------------------------------}

ghcGetVersion :: GhcVersion
ghcGetVersion = GHC78

packageDBFlags :: Bool -> [String] -> [String]
packageDBFlags userDB specificDBs =
     ["-no-user-package-db" | not userDB]
  ++ concat [["-package-db", db] | db <- specificDBs]

-- | Set GHC options
--
-- This is meant to be stateless. It is important to call storeDynFlags at least
-- once before calling setGhcOptions so that we know what state to restore to
-- before setting the options.
--
-- Returns unrecognized options and warnings
setGhcOptions :: [String] -> Ghc ([String], [String])
setGhcOptions opts = do
  dflags <- restoreDynFlags
  (dflags', leftover, warnings) <- parseDynamicFlags dflags (map noLoc opts)
  setupLinkerState =<< setSessionDynFlags dflags'
  return (map unLoc leftover, map unLoc warnings)

-- | Setup linker state to deal with changed package flags
--
-- This follows newDynFlags in ghci, except that in 7.8 there is also the
-- notion of "interactive dynflags", which we are ignoring completely.
-- I'm not sure if that's ok or not.
setupLinkerState :: [PackageId] -> Ghc ()
setupLinkerState newPackages = do
  dflags <- getSessionDynFlags
  setTargets []
  load LoadAllTargets
  liftIO $ linkPackages dflags newPackages

{------------------------------------------------------------------------------
  Backup DynFlags

  Sadly, this hardcodes quite a bit of version-specific information about ghc's
  inner workings. Unfortunately, there is no easy way to know which parts of
  DynFlags should and should not be restored to restore flags. The flag
  specification is given by (see packageDynamicFlags in compiler/main/GHC.hs)

  > package_flags ++ dynamic_flags

  both of which are defined in DynFlags.hs. They are not exported, but this
  would not be particularly useful anyway, as the action associated with a
  flag is given by a shallow embedding, so we cannot walk over them and extract
  the necessary info about DynFlags. At least, we cannot do that in code -- we
  can do it manually, and that is precisely what I've done to obtain the list
  below. Of course, this means it's somewhat error prone.

  In order so that this code can be audited and cross-checked against the
  actual ghc version, and so that it can be modified for future ghc versions,
  we don't just list the end result if this manual traversal, but document the
  process.

  Each of the command line options are defined in terms of a auxiliary
  functions that specify their effect on DynFlags. These auxiliary functions
  are listed below, along with which parts of DynFlags they modify:

  > FUNCTION                   MODIFIES FIELD(s) OF DYNFLAGS
  > ----------------------------------------------------------------------------
  > addCmdlineFramework        cmdlineFrameworks
  > addCmdlineHCInclude        cmdlineHcIncludes
  > addDepExcludeMod           depExcludeMods
  > addDepSuffix               depSuffixes
  > addFrameworkPath           frameworkPaths
  > addGhciScript              ghciScripts
  > addHaddockOpts             haddockOptions
  > addImportPath              importPaths
  > addIncludePath             includePaths
  > addLdInputs                ldInputs
  > addLibraryPath             libraryPaths
  > addOptP                    settings
  > addOptc                    settings
  > addOptl                    settings
  > addPkgConfRef              extraPkgConfs
  > addPluginModuleName        pluginModNames
  > addPluginModuleNameOption  pluginModNameOpts
  > addWay                     ways, packageFlags, extensions, extensionFlags, generalFlags
  > alterSettings              settings
  > clearPkgConf               extraPkgConfs
  > disableGlasgowExts         generalFlags, extensions, extensionFlags
  > distrustPackage            packageFlags
  > enableGlasgowExts          generalFlags, extensions, extensionFlags
  > exposePackage              packageFlags
  > exposePackageId            packageFlags
  > forceRecompile             generalFlags
  > hidePackage                packageFlags
  > ignorePackage              packageFlags
  > parseDynLibLoaderMode      dynLibLoader
  > removeGlobalPkgConf        extraPkgConfs
  > removeUserPkgConf          extraPkgConfs
  > removeWayDyn               ways
  > setDPHOpt                  optLevel, generalFlags, maxSimplIterations, simplPhases
  > setDepIncludePkgDeps       depIncludePkgDeps
  > setDepMakefile             depMakefile
  > setDumpDir                 dumpDir
  > setDumpFlag                dumpFlags, generalFlags
  > setDumpFlag'               dumpFlags, generalFlags
  > setDumpPrefixForce         dumpPrefixForce
  > setDumpSimplPhases         generalFlags, shouldDumpSimplPhase
  > setDylibInstallName        dylibInstallName
  > setDynHiSuf                dynHiSuf
  > setDynObjectSuf            dynObjectSuf
  > setDynOutputFile           dynOutputFile
  > setExtensionFlag           extensions, extensionFlags
  > setGeneralFlag             generalFlags
  > setHcSuf                   hcSuf
  > setHiDir                   hiDir
  > setHiSuf                   hiSuf
  > setInteractivePrint        interactivePrint
  > setLanguage                language, extensionFlags
  > setMainIs                  mainFunIs, mainModIs
  > setObjTarget               hscTarget
  > setObjectDir               objectDir
  > setObjectSuf               objectSuf
  > setOptHpcDir               hpcDir
  > setOptLevel                optLevel, generalFlags
  > setOutputDir               objectDir, hiDir, stubDir, dumpDir
  > setOutputFile              outputFile
  > setOutputHi                outputHi
  > setPackageName             thisPackage
  > setPackageTrust            generalFlags, pkgTrustOnLoc
  > setPgmP                    settings
  > setRtsOpts                 rtsOpts
  > setRtsOptsEnabled          rtsOptsEnabled
  > setSafeHaskell             safeHaskell
  > setStubDir                 stubDir
  > setTarget                  hscTarget
  > setTargetWithPlatform      hscTarget
  > setTmpDir                  settings
  > setVerboseCore2Core        dumpFlags, generalFlags, shouldDumpSimplPhase
  > setVerbosity               verbosity
  > setWarningFlag             warningFlags
  > trustPackage               packageFlags
  > unSetExtensionFlag         extensions, extensionFlags
  > unSetGeneralFlag           generalFlags
  > unSetWarningFlag           warningFlags

  Below is a list of the dynamic_flags in alphabetical order along with the
  auxiliary function that they use. A handful of these flags define their
  effect on DynFlags directly; these are marked (**).

  > FLAG                           DEFINED IN TERMS OF
  > ----------------------------------------------------------------------------
  > "#include"                      addCmdlineHCInclude
  > "D"                             addOptP
  > "F"                             setGeneralFlag
  > "H"                             ** sets ghcHeapSize
  > "I"                             addIncludePath
  > "L"                             addLibraryPath
  > "O"                             setOptLevel
  > "O"                             setOptLevel
  > "Odph"                          setDPHOpt
  > "Onot"                          setOptLevel
  > "Rghc-timing"                   ** sets enableTimeStats
  > "U"                             addOptP
  > "W"                             setWarningFlag
  > "Wall"                          setWarningFlag
  > "Werror"                        setGeneralFlag
  > "Wnot"                          ** sets warningFlags
  > "Wwarn"                         unSetGeneralFlag
  > "auto"                          ** sets profAuto
  > "auto-all"                      ** sets profAuto
  > "caf-all"                       setGeneralFlag
  > "cpp"                           setExtensionFlag
  > "dasm-lint"                     setGeneralFlag
  > "dcmm-lint"                     setGeneralFlag
  > "dcore-lint"                    setGeneralFlag
  > "ddump-asm"                     setDumpFlag
  > "ddump-asm-conflicts"           setDumpFlag
  > "ddump-asm-expanded"            setDumpFlag
  > "ddump-asm-liveness"            setDumpFlag
  > "ddump-asm-native"              setDumpFlag
  > "ddump-asm-regalloc"            setDumpFlag
  > "ddump-asm-regalloc-stages"     setDumpFlag
  > "ddump-asm-stats"               setDumpFlag
  > "ddump-bcos"                    setDumpFlag
  > "ddump-cmm"                     setDumpFlag
  > "ddump-cmm-cbe"                 setDumpFlag
  > "ddump-cmm-cfg"                 setDumpFlag
  > "ddump-cmm-cps"                 setDumpFlag
  > "ddump-cmm-info"                setDumpFlag
  > "ddump-cmm-proc"                setDumpFlag
  > "ddump-cmm-procmap"             setDumpFlag
  > "ddump-cmm-raw"                 setDumpFlag
  > "ddump-cmm-sink"                setDumpFlag
  > "ddump-cmm-sp"                  setDumpFlag
  > "ddump-cmm-split"               setDumpFlag
  > "ddump-core-pipeline"           setDumpFlag
  > "ddump-core-stats"              setDumpFlag
  > "ddump-cs-trace"                setDumpFlag
  > "ddump-cse"                     setDumpFlag
  > "ddump-deriv"                   setDumpFlag
  > "ddump-ds"                      setDumpFlag
  > "ddump-file-prefix"             setDumpPrefixForce
  > "ddump-foreign"                 setDumpFlag
  > "ddump-hi"                      setDumpFlag
  > "ddump-hi-diffs"                setDumpFlag
  > "ddump-hpc"                     setDumpFlag
  > "ddump-if-trace"                setDumpFlag
  > "ddump-inlinings"               setDumpFlag
  > "ddump-llvm"                    setObjTarget, setDumpFlag'
  > "ddump-minimal-imports"         setGeneralFlag
  > "ddump-mod-cycles"              setDumpFlag
  > "ddump-occur-anal"              setDumpFlag
  > "ddump-opt-cmm"                 setDumpFlag
  > "ddump-parsed"                  setDumpFlag
  > "ddump-prep"                    setDumpFlag
  > "ddump-rn"                      setDumpFlag
  > "ddump-rn-stats"                setDumpFlag
  > "ddump-rn-trace"                setDumpFlag
  > "ddump-rtti"                    setDumpFlag
  > "ddump-rule-firings"            setDumpFlag
  > "ddump-rule-rewrites"           setDumpFlag
  > "ddump-rules"                   setDumpFlag
  > "ddump-simpl"                   setDumpFlag
  > "ddump-simpl-iterations"        setDumpFlag
  > "ddump-simpl-phases"            setDumpSimplPhases
  > "ddump-simpl-stats"             setDumpFlag
  > "ddump-simpl-trace"             setDumpFlag
  > "ddump-spec"                    setDumpFlag
  > "ddump-splices"                 setDumpFlag
  > "ddump-stg"                     setDumpFlag
  > "ddump-stranal"                 setDumpFlag
  > "ddump-strsigs"                 setDumpFlag
  > "ddump-tc"                      setDumpFlag
  > "ddump-tc-trace"                setDumpFlag'
  > "ddump-ticked"                  setDumpFlag
  > "ddump-to-file"                 setGeneralFlag
  > "ddump-types"                   setDumpFlag
  > "ddump-vect"                    setDumpFlag
  > "ddump-view-pattern-commoning"  setDumpFlag
  > "ddump-vt-trace"                setDumpFlag
  > "ddump-worker-wrapper"          setDumpFlag
  > "debug"                         addWay
  > "dep-makefile"                  setDepMakefile
  > "dep-suffix"                    addDepSuffix
  > "dfaststring-stats"             setGeneralFlag
  > "dll-split"                     ** sets dllSplitFile, dllSplit
  > "dno-llvm-mangler"              setGeneralFlag
  > "dppr-cols"                     ** sets pprCols
  > "dppr-user-length"              ** sets pprUserLength
  > "dshow-passes"                  forceRecompile, setVerbosity
  > "dsource-stats"                 setDumpFlag
  > "dstg-lint"                     setGeneralFlag
  > "dstg-stats"                    setGeneralFlag
  > "dsuppress-all"                 setGeneralFlag
  > "dtrace-level"                  ** sets traceLevel
  > "dumpdir"                       setDumpDir
  > "dverbose-core2core"            setVerbosity, setVerboseCore2Core
  > "dverbose-stg2stg"              setDumpFlag
  > "dylib-install-name"            setDylibInstallName
  > "dynamic"                       addWay
  > "dynamic-too"                   setGeneralFlag
  > "dynhisuf"                      setDynHiSuf
  > "dynload"                       parseDynLibLoaderMode
  > "dyno"                          setDynOutputFile
  > "dynosuf"                       setDynObjectSuf
  > "eventlog"                      addWay
  > "exclude-module"                addDepExcludeMod
  > "fPIC"                          setGeneralFlag
  > "fasm"                          setObjTarget
  > "fbyte-code"                    setTarget
  > "fcontext-stack"                ** sets ctxtStkDepth
  > "ffloat-all-lams"               ** sets floatLamArgs
  > "ffloat-lam-args"               ** sets floatLamArgs
  > "fghci-hist-size"               ** sets ghciHistSize
  > "fglasgow-exts"                 enableGlasgowExts
  > "fhistory-size"                 ** sets historySize
  > "fliberate-case-threshold"      ** sets liberateCaseThreshold
  > "fllvm"                         setObjTarget
  > "fmax-relevant-binds"           ** sets maxRelevantBinds
  > "fmax-simplifier-iterations"    ** sets maxSimplIterations
  > "fmax-worker-args"              ** sets maxWorkerArgs
  > "fno-PIC"                       unSetGeneralFlag
  > "fno-code"                      setTarget, ** sets ghcLink
  > "fno-glasgow-exts"              disableGlasgowExts
  > "fno-liberate-case-threshold"   ** sets liberateCaseThreshold
  > "fno-max-relevant-binds"        ** sets maxRelevantBinds
  > "fno-prof-auto"                 ** sets profAuto
  > "fno-safe-infer"                setSafeHaskell
  > "fno-spec-constr-count"         ** sets specConstrCount
  > "fno-spec-constr-threshold"     ** sets specConstrThreshold
  > "fobject-code"                  setTargetWithPlatform
  > "fpackage-trust"                setPackageTrust
  > "fplugin"                       addPluginModuleName
  > "fplugin-opt"                   addPluginModuleNameOption
  > "fprof-auto"                    ** sets profAuto
  > "fprof-auto-calls"              ** sets profAuto
  > "fprof-auto-exported"           ** sets profAuto
  > "fprof-auto-top"                ** sets profAuto
  > "framework"                     addCmdlineFramework
  > "framework-path"                addFrameworkPath
  > "frule-check"                   ** sets ruleCheck
  > "fsimpl-tick-factor"            ** sets simplTickFactor
  > "fsimplifier-phases"            ** sets simplPhases
  > "fspec-constr-count"            ** sets specConstrCount
  > "fspec-constr-recursive"        ** sets specConstrRecursive
  > "fspec-constr-threshold"        ** sets specConstrThreshold
  > "fstrictness-before"            ** sets strictnessBefore
  > "ftype-function-depth"          ** sets tyFunStkDepth
  > "funfolding-creation-threshold" ** sets ufCreationThreshold
  > "funfolding-dict-discount"      ** sets ufDictDiscount
  > "funfolding-fun-discount"       ** sets ufFunAppDiscount
  > "funfolding-keeness-factor"     ** sets ufKeenessFactor
  > "funfolding-use-threshold"      ** sets ufUseThreshold
  > "fvia-C"                        <<warning only>>
  > "fvia-c"                        <<warning only>>
  > "ghci-script"                   addGhciScript
  > "gransim"                       addWay
  > "haddock"                       setGeneralFlag
  > "haddock-opts"                  addHaddockOpts
  > "hcsuf"                         setHcSuf
  > "hidir"                         setHiDir
  > "hisuf"                         setHiSuf
  > "hpcdir"                        setOptHpcDir
  > "i"                             addImportPath
  > "include-pkg-deps"              setDepIncludePkgDeps
  > "interactive-print"             setInteractivePrint
  > "j"                             ** sets parMakeCount
  > "keep-hc-file"                  setGeneralFlag
  > "keep-hc-files"                 setGeneralFlag
  > "keep-llvm-file"                setObjTarget, setGeneralFlag
  > "keep-llvm-files"               setObjTarget, setGeneralFlag
  > "keep-raw-s-file"               <<warning only>>
  > "keep-raw-s-files"              <<warning only>>
  > "keep-s-file"                   setGeneralFlag
  > "keep-s-files"                  setGeneralFlag
  > "keep-tmp-files"                setGeneralFlag
  > "l"                             addLdInputs
  > "main-is"                       setMainIs
  > "mavx"                          ** sets avx
  > "mavx2"                         ** sets avx2
  > "mavx512cd"                     ** sets avx512cd
  > "mavx512er"                     ** sets avx512er
  > "mavx512f"                      ** sets avx512f
  > "mavx512pf"                     ** sets avx512pf
  > "monly-2-regs"                  <<warning only>>
  > "monly-3-regs"                  <<warning only>>
  > "monly-4-regs"                  <<warning only>>
  > "msse"                          ** sets sseVersion
  > "n"                             <<warning only>>
  > "ndp"                           addWay
  > "no-auto"                       ** sets profAuto
  > "no-auto-all"                   ** sets profAuto
  > "no-auto-link-packages"         unSetGeneralFlag
  > "no-caf-all"                    unSetGeneralFlag
  > "no-hs-main"                    setGeneralFlag
  > "no-link"                       ** sets ghcLink
  > "no-recomp"                     setGeneralFlag
  > "no-rtsopts"                    setRtsOptsEnabled
  > "o"                             setOutputFile
  > "odir"                          setObjectDir
  > "ohi"                           setOutputHi
  > "optF"                          alterSettings
  > "optL"                          alterSettings
  > "optP"                          addOptP
  > "opta"                          alterSettings
  > "optc"                          addOptc
  > "optdep--exclude-module"        addDepExcludeMod
  > "optdep--include-pkg-deps"      setDepIncludePkgDeps
  > "optdep--include-prelude"       setDepIncludePkgDeps
  > "optdep-f"                      setDepMakefile
  > "optdep-s"                      addDepSuffix
  > "optdep-w"                      <<warning only>>
  > "optdep-x"                      addDepExcludeMod
  > "optl"                          addOptl
  > "optlc"                         alterSettings
  > "optlo"                         alterSettings
  > "optm"                          <<warning only>>
  > "optwindres"                    alterSettings
  > "osuf"                          setObjectSuf
  > "outputdir"                     setOutputDir
  > "parallel"                      addWay
  > "pgmF"                          alterSettings
  > "pgmL"                          alterSettings
  > "pgmP"                          setPgmP
  > "pgma"                          alterSettings
  > "pgmc"                          alterSettings
  > "pgmdll"                        alterSettings
  > "pgml"                          alterSettings
  > "pgmlc"                         alterSettings
  > "pgmlibtool"                    alterSettings
  > "pgmlo"                         alterSettings
  > "pgmm"                          <<warning only>>
  > "pgms"                          alterSettings
  > "pgmwindres"                    alterSettings
  > "prof"                          addWay
  > "rdynamic"                      <<does nothing>>
  > "recomp"                        unSetGeneralFlag
  > "relative-dynlib-paths"         setGeneralFlag
  > "rtsopts"                       setRtsOptsEnabled
  > "rtsopts=all"                   setRtsOptsEnabled
  > "rtsopts=none"                  setRtsOptsEnabled
  > "rtsopts=some"                  setRtsOptsEnabled
  > "shared"                        ** sets ghcLink
  > "smp"                           addWay
  > "split-objs"                    setGeneralFlag
  > "static"                        removeWayDyn
  > "staticlib"                     ** sets ghcLink
  > "stubdir"                       setStubDir
  > "threaded"                      addWay
  > "ticky"                         setGeneralFlag
  > "ticky-LNE"                     setGeneralFlag
  > "ticky-allocd"                  setGeneralFlag
  > "ticky-dyn-thunk"               setGeneralFlag
  > "tmpdir"                        setTmpDir
  > "v"                             setVerbosity
  > "w"                             ** sets warningFlags
  > "with-rtsopts"                  setRtsOpts

  Finally, there is a bunch of flags defined in terms of setGeneralFlag,
  unSetGeneralFlag, setWarningFlag, unSetWarningFlag, setExtensionFlag,
  unSetExtensionFlag, setLanguage, and setSafeHaskell.

  The same list for package_flags:

  > FLAG                           DEFINED IN TERMS OF
  > ----------------------------------------------------------------------------
  > "clear-package-db"      clearPkgConf
  > "distrust"              distrustPackage
  > "distrust-all-packages" setGeneralFlag
  > "global-package-db"     addPkgConfRef
  > "hide-all-packages"     setGeneralFlag
  > "hide-package"          hidePackage
  > "ignore-package"        ignorePackage
  > "no-global-package-db"  removeGlobalPkgConf
  > "no-user-package-conf"  removeUserPkgConf
  > "no-user-package-db"    removeUserPkgConf
  > "package"               exposePackage
  > "package-conf"          addPkgConfRef
  > "package-db"            addPkgConfRef
  > "package-id"            exposePackageId
  > "package-name"          setPackageName
  > "syslib"                exposePackage
  > "trust"                 trustPackage
  > "user-package-db"       addPkgConfRef

  In addition to the above, we also reset one more field: pkgDatabase. The
  pkgDatabase is initialized on the first call to initPackages (and hence the
  first call to setSessionDynFlags), which happens at server startup.  After
  that, subsequent calls to setSessionDynFlags take the _existing_ pkgDatabase,
  but applies the "batch package flags" to it (hide-all-packages,
  distrust-all-packages). However, it doesn't "unapply" these batch flags. By
  restoring the pkgDatabase to the value it gets at server startup, we
  effectively restore these batch flags whenever we apply user settings.
------------------------------------------------------------------------------}

dynFlagsRef :: IORef DynFlags
{-# NOINLINE dynFlagsRef #-}
dynFlagsRef = unsafePerformIO $ newIORef (error "No DynFlags stored yet")

storeDynFlags :: Ghc ()
storeDynFlags = do
  dynFlags <- getSessionDynFlags
  liftIO $ writeIORef dynFlagsRef dynFlags

restoreDynFlags :: Ghc DynFlags
restoreDynFlags = do
  storedDynFlags  <- liftIO $ readIORef dynFlagsRef
  currentDynFlags <- getSessionDynFlags
  return (currentDynFlags `restoreDynFlagsFrom` storedDynFlags)

-- | Copy over all fields of DynFlags that are affected by dynamic_flags
-- and package_flags (and only those)
--
-- See detailed description above.
restoreDynFlagsFrom :: DynFlags -> DynFlags -> DynFlags
restoreDynFlagsFrom new old = new {
    avx                   = avx                   old
  , avx2                  = avx2                  old
  , avx512cd              = avx512cd              old
  , avx512er              = avx512er              old
  , avx512f               = avx512f               old
  , avx512pf              = avx512pf              old
  , cmdlineFrameworks     = cmdlineFrameworks     old
  , cmdlineHcIncludes     = cmdlineHcIncludes     old
  , ctxtStkDepth          = ctxtStkDepth          old
  , depExcludeMods        = depExcludeMods        old
  , depIncludePkgDeps     = depIncludePkgDeps     old
  , depMakefile           = depMakefile           old
  , depSuffixes           = depSuffixes           old
  , dllSplit              = dllSplit              old
  , dllSplitFile          = dllSplitFile          old
  , dumpDir               = dumpDir               old
  , dumpFlags             = dumpFlags             old
  , dumpPrefixForce       = dumpPrefixForce       old
  , dylibInstallName      = dylibInstallName      old
  , dynHiSuf              = dynHiSuf              old
  , dynLibLoader          = dynLibLoader          old
  , dynObjectSuf          = dynObjectSuf          old
  , dynOutputFile         = dynOutputFile         old
  , enableTimeStats       = enableTimeStats       old
  , extensionFlags        = extensionFlags        old
  , extensions            = extensions            old
  , extraPkgConfs         = extraPkgConfs         old
  , floatLamArgs          = floatLamArgs          old
  , frameworkPaths        = frameworkPaths        old
  , generalFlags          = generalFlags          old
  , ghcHeapSize           = ghcHeapSize           old
  , ghcLink               = ghcLink               old
  , ghciHistSize          = ghciHistSize          old
  , ghciScripts           = ghciScripts           old
  , haddockOptions        = haddockOptions        old
  , hcSuf                 = hcSuf                 old
  , hiDir                 = hiDir                 old
  , hiSuf                 = hiSuf                 old
  , historySize           = historySize           old
  , hpcDir                = hpcDir                old
  , hscTarget             = hscTarget             old
  , importPaths           = importPaths           old
  , includePaths          = includePaths          old
  , interactivePrint      = interactivePrint      old
  , language              = language              old
  , ldInputs              = ldInputs              old
  , liberateCaseThreshold = liberateCaseThreshold old
  , libraryPaths          = libraryPaths          old
  , mainFunIs             = mainFunIs             old
  , mainModIs             = mainModIs             old
  , maxRelevantBinds      = maxRelevantBinds      old
  , maxSimplIterations    = maxSimplIterations    old
  , maxWorkerArgs         = maxWorkerArgs         old
  , objectDir             = objectDir             old
  , objectSuf             = objectSuf             old
  , optLevel              = optLevel              old
  , outputFile            = outputFile            old
  , outputHi              = outputHi              old
  , packageFlags          = packageFlags          old
  , parMakeCount          = parMakeCount          old
  , pkgDatabase           = pkgDatabase           old
  , pkgTrustOnLoc         = pkgTrustOnLoc         old
  , pluginModNameOpts     = pluginModNameOpts     old
  , pluginModNames        = pluginModNames        old
  , pprCols               = pprCols               old
  , pprUserLength         = pprUserLength         old
  , profAuto              = profAuto              old
  , rtsOpts               = rtsOpts               old
  , rtsOptsEnabled        = rtsOptsEnabled        old
  , ruleCheck             = ruleCheck             old
  , safeHaskell           = safeHaskell           old
  , settings              = settings              old
  , shouldDumpSimplPhase  = shouldDumpSimplPhase  old
  , simplPhases           = simplPhases           old
  , simplTickFactor       = simplTickFactor       old
  , specConstrCount       = specConstrCount       old
  , specConstrRecursive   = specConstrRecursive   old
  , specConstrThreshold   = specConstrThreshold   old
  , sseVersion            = sseVersion            old
  , strictnessBefore      = strictnessBefore      old
  , stubDir               = stubDir               old
  , thisPackage           = thisPackage           old
  , traceLevel            = traceLevel            old
  , tyFunStkDepth         = tyFunStkDepth         old
  , ufCreationThreshold   = ufCreationThreshold   old
  , ufDictDiscount        = ufDictDiscount        old
  , ufFunAppDiscount      = ufFunAppDiscount      old
  , ufKeenessFactor       = ufKeenessFactor       old
  , ufUseThreshold        = ufUseThreshold        old
  , verbosity             = verbosity             old
  , warningFlags          = warningFlags          old
  , ways                  = ways                  old
  }

{------------------------------------------------------------------------------
  Traversing the AST
------------------------------------------------------------------------------}

instance FoldId Name where
  foldId   = astName
  ifPostTc = \_phantom -> const Nothing

instance FoldId Id where
  foldId   = astVar
  ifPostTc = \_phantom -> Just

instance Fold a => Fold [a] where
  fold alg xs = do
    mapM_ (fold alg) xs
    return Nothing

instance Fold a => Fold (Maybe a) where
  fold _alg Nothing  = return Nothing
  fold  alg (Just x) = fold alg x

instance FoldId id => Fold (HsGroup id) where
  fold alg HsGroup { hs_valds
                   , hs_tyclds
                   , hs_instds
                   , hs_derivds
                   , hs_fixds
                   , hs_defds
                   , hs_fords
                   , hs_warnds
                   , hs_annds
                   , hs_ruleds
                   , hs_vects
                   , hs_docs } = astMark alg Nothing "HsGroup" $ do
    fold alg hs_valds
    fold alg hs_tyclds
    fold alg hs_instds
    fold alg hs_derivds
    fold alg hs_fixds
    fold alg hs_defds
    fold alg hs_fords
    fold alg hs_warnds
    fold alg hs_annds
    fold alg hs_ruleds
    fold alg hs_vects
    fold alg hs_docs

instance FoldId id => Fold (HsValBinds id) where
  fold _alg (ValBindsIn {}) =
    fail "fold alg: Unexpected ValBindsIn"
  fold alg (ValBindsOut binds sigs) = astMark alg Nothing "ValBindsOut" $ do
    fold alg (map snd binds)
    fold alg sigs

instance FoldId id => Fold (LSig id) where
  fold alg (L span (TypeSig names tp)) = astMark alg (Just span) "TypeSig" $ do
    forM_ names $ \name -> foldId alg name SigSite
    fold alg tp
  fold alg (L span (PatSynSig name
                              _{-TODO?: (HsPatSynDetails (LHsType name))-}
                              tp
                              _{-TODO?: (LHsContext name)-}
                              _{-TODO?: (LHsContext name)-})
           ) = astMark alg (Just span) "PatSynSig" $ do
    foldId alg name SigSite
    fold alg tp
  fold alg (L span (GenericSig names tp)) = astMark alg (Just span) "GenericSig" $ do
    forM_ names $ \name -> foldId alg name SigSite
    fold alg tp

  -- Only in generated code
  fold alg (L span (IdSig _)) = astMark alg (Just span) "IdSig" $
    return Nothing

  -- Annotations
  fold alg (L span (FixSig _)) = astMark alg (Just span) "FixSig" $
    return Nothing
  fold alg (L span (InlineSig _ _)) = astMark alg (Just span) "InlineSig" $
    return Nothing
  fold alg (L span (SpecSig _ _ _)) = astMark alg (Just span) "SpecSig" $
    return Nothing
  fold alg (L span (SpecInstSig _)) = astMark alg (Just span) "SpecInstSig" $
    return Nothing
  fold alg (L span (MinimalSig _)) = astMark alg (Just span) "MinimalSig" $
    return Nothing

instance FoldId id => Fold (LHsType id) where
  fold alg (L span (HsFunTy arg res)) = astMark alg (Just span) "HsFunTy" $
    fold alg [arg, res]
  fold alg (L span (HsTyVar name)) = astMark alg (Just span) "HsTyVar" $
    foldId alg (L span name) UseSite
  fold alg (L span (HsForAllTy explicitFlag tyVars ctxt body)) = astMark alg (Just span) "hsForAllTy" $ do
    case explicitFlag of
      Explicit -> fold alg tyVars
      Implicit -> return Nothing
    fold alg ctxt
    fold alg body
  fold alg (L span (HsAppTy fun arg)) = astMark alg (Just span) "HsAppTy" $
    fold alg [fun, arg]
  fold alg (L span (HsTupleTy _tupleSort typs)) = astMark alg (Just span) "HsTupleTy" $
    -- tupleSort is unboxed/boxed/etc.
    fold alg typs
  fold alg (L span (HsListTy typ)) = astMark alg (Just span) "HsListTy" $
    fold alg typ
  fold alg (L span (HsPArrTy typ)) = astMark alg (Just span) "HsPArrTy" $
    fold alg typ
  fold alg (L span (HsParTy typ)) = astMark alg (Just span) "HsParTy" $
    fold alg typ
  fold alg (L span (HsEqTy a b)) = astMark alg (Just span) "HsEqTy" $
    fold alg [a, b]
  fold alg (L span (HsDocTy typ _doc)) = astMark alg (Just span) "HsDocTy" $
    -- I don't think HsDocTy actually makes it through the renamer
    fold alg typ
  fold alg (L span (HsWrapTy _wrapper _typ)) = astMark alg (Just span) "HsWrapTy" $
    -- This is returned only by the type checker, and _typ is not located
    return Nothing
  fold alg (L span (HsRecTy fields)) = astMark alg (Just span) "HsRecTy" $
    fold alg fields
  fold alg (L span (HsKindSig typ kind)) = astMark alg (Just span) "HsKindSig" $
    fold alg [typ, kind]
  fold alg (L span (HsBangTy _bang typ)) = astMark alg (Just span) "HsBangTy" $
    fold alg typ
  fold alg (L span (HsOpTy left (_wrapper, op) right)) = astMark alg (Just span) "HsOpTy" $ do
    fold alg [left, right]
    foldId alg op UseSite
  fold alg (L span (HsIParamTy _var typ)) = astMark alg (Just span) "HsIParamTy" $
    -- _var is not located
    fold alg typ
  fold alg (L span (HsSpliceTy splice _postTcKind)) = astMark alg (Just span) "HsSpliceTy" $
    fold alg (L span splice) -- reuse location info
  fold alg (L span (HsCoreTy _)) = astMark alg (Just span) "HsCoreTy" $
    -- Not important: doesn't arise until later in the compiler pipeline
    return Nothing
  fold alg (L span (HsQuasiQuoteTy qquote))  = astMark alg (Just span) "HsQuasiQuoteTy" $
    fold alg (L span qquote) -- reuse location info
  fold alg (L span (HsExplicitListTy _postTcKind typs)) = astMark alg (Just span) "HsExplicitListTy" $
    fold alg typs
  fold alg (L span (HsExplicitTupleTy _postTcKind typs)) = astMark alg (Just span) "HsExplicitTupleTy" $
    fold alg typs
  fold alg (L span (HsTyLit _hsTyLit)) = astMark alg (Just span) "HsTyLit" $
    return Nothing

instance FoldId id => Fold (Located (HsSplice id)) where
  fold alg (L span (HsSplice _id expr)) = astMark alg (Just span) "HsSplice" $ do
    fold alg expr

instance FoldId id => Fold (Located (HsQuasiQuote id)) where
  fold alg (L span (HsQuasiQuote _id _srcSpan _enclosed)) = astMark alg (Just span) "HsQuasiQuote" $
    -- Unfortunately, no location information is stored within HsQuasiQuote at all
    return Nothing

instance FoldId id => Fold (LHsTyVarBndr id) where
  fold alg (L span (UserTyVar name)) = astMark alg (Just span) "UserTyVar" $ do
    foldId alg (L span name) DefSite
  fold alg (L span (KindedTyVar name kind)) = astMark alg (Just span) "KindedTyVar" $ do
    foldId alg (L span name) DefSite
    fold alg kind

instance FoldId id => Fold (LHsContext id) where
  fold alg (L span typs) = astMark alg (Just span) "LHsContext" $
    fold alg typs

instance FoldId id => Fold (LHsBinds id) where
  fold alg = fold alg . bagToList

instance FoldId id => Fold (LHsBind id) where
  fold alg (L span bind@(FunBind {})) = astMark alg (Just span) "FunBind" $ do
    foldId alg (fun_id bind) DefSite
    fold alg (fun_matches bind)
  fold alg (L span bind@(PatBind {})) = astMark alg (Just span) "PatBind" $ do
    fold alg (pat_lhs bind)
    fold alg (pat_rhs bind)
  fold alg (L span _bind@(VarBind {})) = astMark alg (Just span) "VarBind" $
    -- These are only introduced by the type checker, and don't involve user
    -- written code. The ghc comments says "located 'only for consistency'"
    return Nothing
  fold alg (L span bind@(AbsBinds {})) = astMark alg (Just span) "AbsBinds" $ do
    forM_ (abs_exports bind) $ \abs_export ->
      foldId alg (L typecheckOnly (abe_poly abs_export)) DefSite
    fold alg (abs_binds bind)
  fold alg (L span bind@(PatSynBind {})) = astMark alg (Just span)
                                             "PatSynBind" $ do
    foldId alg (patsyn_id bind) DefSite
    fold alg (patsyn_def bind)
      -- TODO?: patsyn_args :: HsPatSynDetails (Located idR)
      --        patsyn_dir  :: HsPatSynDir idR

typecheckOnly :: SrcSpan
typecheckOnly = mkGeneralSrcSpan (fsLit "<typecheck only>")

instance (FoldId id, Fold body) => Fold (MatchGroup id body) where
  -- We ignore the postTcType, as it doesn't have location information
  -- TODO: _mg_origin distinguishes between FromSource and Generated.
  -- May be useful to take that into account? (Here and elsewhere)
  fold alg (MG mg_alts _mg_arg_tys _mg_res_ty _mg_origin) = astMark alg Nothing "MG" $
    fold alg mg_alts

instance (FoldId id, Fold body) => Fold (LMatch id body) where
  fold alg (L span (Match pats _type rhss)) = astMark alg (Just span) "Match" $ do
    fold alg pats
    fold alg rhss

instance (FoldId id, Fold body) => Fold (GRHSs id body) where
  fold alg (GRHSs rhss binds) = astMark alg Nothing "GRHSs" $ do
    fold alg rhss
    fold alg binds

instance (FoldId id, Fold body) => Fold (LGRHS id body) where
  fold alg (L span (GRHS _guards rhs)) = astMark alg (Just span) "GRHS" $
    fold alg rhs

instance FoldId id => Fold (HsLocalBinds id) where
  fold _alg EmptyLocalBinds =
    return Nothing
  fold _alg (HsValBinds (ValBindsIn _ _)) =
    fail "fold alg: Unexpected ValBindsIn (after renamer these should not exist)"
  fold alg (HsValBinds (ValBindsOut binds sigs)) = astMark alg Nothing "HsValBinds" $ do
    fold alg (map snd binds) -- "fst" is 'rec flag'
    fold alg sigs
  fold alg (HsIPBinds binds) =
    fold alg binds

instance FoldId id => Fold (HsIPBinds id) where
  fold alg (IPBinds binds _evidence) =
    fold alg binds

instance FoldId id => Fold (LIPBind id) where
  fold alg (L span (IPBind _name expr)) = astMark alg (Just span) "IPBind" $ do
    -- Name is not located :(
    fold alg expr

instance FoldId id => Fold (LHsExpr id) where
  fold alg (L span (HsPar expr)) = astMark alg (Just span) "HsPar" $
    fold alg expr
  fold alg (L span (ExprWithTySig expr _type)) = astMark alg (Just span) "ExprWithTySig" $
    fold alg expr
  fold alg (L span (ExprWithTySigOut expr _type)) = astMark alg (Just span) "ExprWithTySigOut" $
    fold alg expr
  fold alg (L span (HsOverLit (OverLit{ol_type}))) = astMark alg (Just span) "HsOverLit" $ do
    astExpType alg span (ifPostTc (undefined :: id) ol_type)
  fold alg (L span (OpApp left op _fix right)) = astMark alg (Just span) "OpApp" $ do
    _leftTy  <- fold alg left
    opTy     <- fold alg op
    _rightTy <- fold alg right
    astExpType alg span (funRes2 <$> opTy)
  fold alg (L span (HsVar id)) = astMark alg (Just span) "HsVar" $ do
    foldId alg (L span id) UseSite
  fold alg (L span (HsWrap wrapper expr)) = astMark alg (Just span) "HsWrap" $ do
    ty <- fold alg (L span expr)
    astExpType alg span (applyWrapper wrapper <$> ty)
  fold alg (L span (HsLet binds expr)) = astMark alg (Just span) "HsLet" $ do
    fold alg binds
    ty <- fold alg expr
    astExpType alg span ty -- Re-foldId alg this with the span of the whole let
  fold alg (L span (HsApp fun arg)) = astMark alg (Just span) "HsApp" $ do
    funTy  <- fold alg fun
    _argTy <- fold alg arg
    astExpType alg span (funRes1 <$> funTy)
  fold alg (L span (HsLit lit)) =
    -- Intentional omission of the "astMark alg" debugging call here.
    -- The syntax "assert" is replaced by GHC by "assertError <span>", where
    -- both "assertError" and the "<span>" are assigned the source span of
    -- the original "assert". This means that the <span> (represented as an
    -- HsLit) might override "assertError" in the IdMap.
    astExpType alg span (ifPostTc (undefined :: id) (hsLitType lit))
  fold alg (L span (HsLam matches@(MG _ mg_arg_tys mg_res_ty _ms_origin))) = astMark alg (Just span) "HsLam" $ do
    fold alg matches
    let lamTy = do arg_tys <- sequence $ map (ifPostTc (undefined :: id)) mg_arg_tys
                   res_ty  <- ifPostTc (undefined :: id) mg_res_ty
                   return (mkFunTys arg_tys res_ty)
    astExpType alg span lamTy
  fold alg (L span (HsDo _ctxt stmts postTcType)) = astMark alg (Just span) "HsDo" $ do
    -- ctxt indicates what kind of statement it is; AFAICT there is no
    -- useful information in it for us
    fold alg stmts
    astExpType alg span (ifPostTc (undefined :: id) postTcType)
  fold alg (L span (ExplicitList postTcType _mSyntaxExpr exprs)) = astMark alg (Just span) "ExplicitList" $ do
    fold alg exprs
    astExpType alg span (mkListTy <$> ifPostTc (undefined :: id) postTcType)
  fold alg (L span (RecordCon con mPostTcExpr recordBinds)) = astMark alg (Just span) "RecordCon" $ do
    fold alg recordBinds
    case ifPostTc (undefined :: id) mPostTcExpr of
      Nothing -> do
        foldId alg con UseSite
        return Nothing
      Just postTcExpr -> do
        conTy <- fold alg (L (getLoc con) postTcExpr)
        astExpType alg span (funResN <$> conTy)
  fold alg (L span (HsCase expr matches@(MG _ _mg_arg_tys mg_res_ty _mg_origin))) = astMark alg (Just span) "HsCase" $ do
    fold alg expr
    fold alg matches
    astExpType alg span (ifPostTc (undefined :: id) mg_res_ty)
  fold alg (L span (ExplicitTuple args boxity)) = astMark alg (Just span) "ExplicitTuple" $ do
    argTys <- mapM (fold alg) args
    astExpType alg span (mkTupleTy (boxityNormalTupleSort boxity) <$> sequence argTys)
  fold alg (L span (HsIf _rebind cond true false)) = astMark alg (Just span) "HsIf" $ do
    _condTy <- fold alg cond
    _trueTy <- fold alg true
    falseTy <- fold alg false
    astExpType alg span falseTy
  fold alg (L span (SectionL arg op)) = astMark alg (Just span) "SectionL" $ do
    _argTy <- fold alg arg
    opTy   <- fold alg op
    astExpType alg span (mkSectionLTy <$> opTy)
   where
      mkSectionLTy ty = let (_arg1, arg2, res) = splitFunTy2 ty
                        in mkFunTy arg2 res
  fold alg (L span (SectionR op arg)) = astMark alg (Just span) "SectionR" $ do
    opTy   <- fold alg op
    _argTy <- fold alg arg
    astExpType alg span (mkSectionRTy <$> opTy)
   where
      mkSectionRTy ty = let (arg1, _arg2, res) = splitFunTy2 ty
                        in mkFunTy arg1 res
  fold alg (L span (HsIPVar _name)) = astMark alg (Just span) "HsIPVar" $
    -- _name is not located :(
    return Nothing
  fold alg (L span (NegApp expr _rebind)) = astMark alg (Just span) "NegApp" $ do
    ty <- fold alg expr
    astExpType alg span ty
  fold alg (L span (HsBracket th)) = astMark alg (Just span) "HsBracket" $
    fold alg th
  fold alg (L span (HsRnBracketOut _th _pendingSplices)) = astMark alg (Just span) "HsRnBracketOut" $ do
    -- See comments for HsTcBracketOut
    return Nothing
  fold alg (L span (HsTcBracketOut th pendingSplices)) = astMark alg (Just span) "HsTcBracketOut" $ do
    -- Given something like
    --
    -- > \x xs -> [| x : xs |]
    --
    -- @pendingSplices@ contains
    --
    -- > [ "x",  "Language.Haskell.TH.Syntax.lift x"
    -- > , "xs", "Language.Haskell.TH.Syntax.lift xs"
    -- > ]
    --
    -- Sadly, however, ghc attaches <no location info> to these splices.
    -- Moreover, we don't get any type information about the whole bracket
    -- expression either :(
    forM_ pendingSplices $ \(_name, splice) -> fold alg splice
    fold alg th
  fold alg (L span (RecordUpd expr binds _dataCons _postTcTypeInp _postTcTypeOutp)) = astMark alg (Just span) "RecordUpd" $ do
    recordTy <- fold alg expr
    fold alg binds
    astExpType alg span recordTy -- The type doesn't change
  fold alg (L span (HsProc pat body)) = astMark alg (Just span) "HsProc" $ do
    fold alg pat
    fold alg body
  fold alg (L span (HsArrApp arr inp _postTcType _arrType _orient)) = astMark alg (Just span) "HsArrApp" $ do
    fold alg [arr, inp]
  fold alg (L span (HsArrForm expr _fixity cmds)) = astMark alg (Just span) "HsArrForm" $ do
    fold alg expr
    fold alg cmds
  fold alg (L span (HsTick _tickish expr)) = astMark alg (Just span) "HsTick" $ do
    fold alg expr
  fold alg (L span (HsBinTick _trueTick _falseTick expr)) = astMark alg (Just span) "HsBinTick" $ do
    fold alg expr
  fold alg (L span (HsTickPragma _span expr)) = astMark alg (Just span) "HsTickPragma" $ do
    fold alg expr
  fold alg (L span (HsSCC _string expr)) = astMark alg (Just span) "HsSCC" $ do
    fold alg expr
  fold alg (L span (HsCoreAnn _string expr)) = astMark alg (Just span) "HsCoreAnn" $ do
    fold alg expr
  fold alg (L span (HsSpliceE _isTyped splice)) = astMark alg (Just span) "HsSpliceE" $ do
    fold alg (L span splice) -- reuse span
  fold alg (L span (HsQuasiQuoteE qquote)) = astMark alg (Just span) "HsQuasiQuoteE" $ do
    fold alg (L span qquote) -- reuse span
  fold alg (L span (ExplicitPArr _postTcType exprs)) = astMark alg (Just span) "ExplicitPArr" $ do
    fold alg exprs
  fold alg (L span (PArrSeq _postTcType seqInfo)) = astMark alg (Just span) "PArrSeq" $ do
    fold alg seqInfo

  -- According to the comments in HsExpr.lhs,
  -- "These constructors only appear temporarily in the parser.
  -- The renamer translates them into the Right Thing."
  fold alg (L span EWildPat) = astMark alg (Just span) "EWildPat" $
    return Nothing
  fold alg (L span (EAsPat _ _)) = astMark alg (Just span) "EAsPat" $
    return Nothing
  fold alg (L span (EViewPat _ _)) = astMark alg (Just span) "EViewPat" $
    return Nothing
  fold alg (L span (ELazyPat _)) = astMark alg (Just span) "ELazyPat" $
    return Nothing
  fold alg (L span (HsType _ )) = astMark alg (Just span) "HsType" $
    return Nothing
  fold alg (L span (ArithSeq mPostTcExpr _mSyntaxExpr seqInfo)) = astMark alg (Just span) "ArithSeq" $ do
    fold alg seqInfo
    case ifPostTc (undefined :: id) mPostTcExpr of
      Just postTcExpr -> fold alg (L span postTcExpr)
      Nothing         -> return Nothing

  -- New expressions
  fold _ (L _ (HsLamCase _ _)) =
    return Nothing -- FIXME
  fold _ (L _ (HsMultiIf _ _)) =
    return Nothing -- FIXME

  -- Unbound variables are errors?
  fold _alg (L _span (HsUnboundVar _rdrName)) =
    return Nothing

instance FoldId id => Fold (ArithSeqInfo id) where
  fold alg (From expr) = astMark alg Nothing "From" $
    fold alg expr
  fold alg (FromThen frm thn) = astMark alg Nothing "FromThen" $
    fold alg [frm, thn]
  fold alg (FromTo frm to) = astMark alg Nothing "FromTo" $
    fold alg [frm, to]
  fold alg (FromThenTo frm thn to) = astMark alg Nothing "FromThenTo" $
    fold alg [frm, thn, to]

instance FoldId id => Fold (LHsCmdTop id) where
  fold alg (L span (HsCmdTop cmd _postTcTypeInp _postTcTypeRet _syntaxTable)) = astMark alg (Just span) "HsCmdTop" $
    fold alg cmd

instance FoldId id => Fold (HsBracket id) where
  fold alg (ExpBr expr) = astMark alg Nothing "ExpBr" $
    fold alg expr
  fold alg (PatBr pat) = astMark alg Nothing "PatBr" $
    fold alg pat
  fold alg (DecBrG group) = astMark alg Nothing "DecBrG" $
    fold alg group
  fold alg (TypBr typ) = astMark alg Nothing "TypBr" $
    fold alg typ
  fold alg (VarBr _namespace _id) = astMark alg Nothing "VarBr" $
    -- No location information, sadly
    return Nothing
  fold alg (DecBrL decls) = astMark alg Nothing "DecBrL" $
    fold alg decls
  fold alg (TExpBr expr) = astMark alg Nothing "TExpBr" $
    fold alg expr

instance FoldId id => Fold (HsTupArg id) where
  fold alg (Present arg) =
    fold alg arg
  fold _alg (Missing _postTcType) =
    return Nothing

instance (Fold a, FoldId id) => Fold (HsRecFields id a) where
  fold alg (HsRecFields rec_flds _rec_dotdot) = astMark alg Nothing "HsRecFields" $
    fold alg rec_flds

instance (Fold a, FoldId id) => Fold (HsRecField id a) where
  fold alg (HsRecField id arg _pun) = astMark alg Nothing "HsRecField" $ do
    foldId alg id UseSite
    fold alg arg

-- The meaning of the constructors of LStmt isn't so obvious; see various
-- notes in ghc/compiler/hsSyn/HsExpr.lhs
instance (FoldId id, Fold body) => Fold (LStmt id body) where
  fold alg (L span (LastStmt body _syntaxExpr)) = astMark alg (Just span) "LastStmt" $ do
    fold alg body
  fold alg (L span (BindStmt pat expr _bind _fail)) = astMark alg (Just span) "BindStmt" $ do
    -- Neither _bind or _fail are located
    fold alg pat
    fold alg expr
  fold alg (L span (BodyStmt body _seq _guard _postTcType)) = astMark alg (Just span) "BodyStmt" $ do
    -- TODO: should we do something with _postTcType?
    -- (Comment in HsExpr.lhs says it's for arrows)
    fold alg body
  fold alg (L span (LetStmt binds)) = astMark alg (Just span) "LetStmt" $
    fold alg binds
  fold alg (L span stmt@(RecStmt {})) = astMark alg (Just span) "RecStmt" $ do
    fold alg (recS_stmts stmt)

  fold alg (L span (TransStmt {}))  = astUnsupported alg (Just span) "TransStmt"
  fold alg (L span (ParStmt _ _ _)) = astUnsupported alg (Just span) "ParStmt"

instance FoldId id => Fold (LPat id) where
  fold alg (L span (WildPat postTcType)) = astMark alg (Just span) "WildPat" $
    astExpType alg span (ifPostTc (undefined :: id) postTcType)
  fold alg (L span (VarPat id)) = astMark alg (Just span) "VarPat" $
    foldId alg (L span id) DefSite
  fold alg (L span (LazyPat pat)) = astMark alg (Just span) "LazyPat" $
    fold alg pat
  fold alg (L span (AsPat id pat)) = astMark alg (Just span) "AsPat" $ do
    foldId alg id DefSite
    fold alg pat
  fold alg (L span (ParPat pat)) = astMark alg (Just span) "ParPat" $
    fold alg pat
  fold alg (L span (BangPat pat)) = astMark alg (Just span) "BangPat" $
    fold alg pat
  fold alg (L span (ListPat pats _postTcType _mSyntaxExpr)) = astMark alg (Just span) "ListPat" $
    fold alg pats
  fold alg (L span (TuplePat pats _boxity _postTcType)) = astMark alg (Just span) "TuplePat" $
    fold alg pats
  fold alg (L span (PArrPat pats _postTcType)) = astMark alg (Just span) "PArrPat" $
    fold alg pats
  fold alg (L span (ConPatIn con details)) = astMark alg (Just span) "ConPatIn" $ do
    -- Unlike ValBindsIn and HsValBindsIn, we *do* get ConPatIn
    foldId alg con UseSite -- the constructor name is non-binding
    fold alg details
  fold alg (L span (ConPatOut {pat_con, pat_args})) = astMark alg (Just span) "ConPatOut" $ do
    foldId alg (L (getLoc pat_con) (getName (unLoc pat_con))) UseSite
    fold alg pat_args
  fold alg (L span (LitPat _)) = astMark alg (Just span) "LitPat" $
    return Nothing
  fold alg (L span (NPat _ _ _)) = astMark alg (Just span) "NPat" $
    return Nothing
  fold alg (L span (NPlusKPat id _lit _rebind1 _rebind2)) = astMark alg (Just span) "NPlusKPat" $ do
    foldId alg id DefSite
  fold alg (L span (ViewPat expr pat _postTcType)) = astMark alg (Just span) "ViewPat" $ do
    fold alg expr
    fold alg pat
  fold alg (L span (SigPatIn pat typ)) = astMark alg (Just span) "SigPatIn" $ do
    fold alg pat
    fold alg typ
  fold alg (L span (SigPatOut pat _typ)) = astMark alg (Just span) "SigPatOut" $ do
    -- _typ is not located
    fold alg pat
  fold alg (L span (QuasiQuotePat qquote)) = astMark alg (Just span) "QuasiQuotePat" $
    fold alg (L span qquote) -- reuse span
  fold alg (L span (SplicePat splice)) = astMark alg (Just span) "SplicePat" $
    fold alg (L span splice) -- reuse span

  -- During translation only
  fold alg (L span (CoPat _ _ _)) = astMark alg (Just span) "CoPat" $
    return Nothing

instance (Fold arg, Fold rec) => Fold (HsConDetails arg rec) where
  fold alg (PrefixCon args) = astMark alg Nothing "PrefixCon" $
    fold alg args
  fold alg (RecCon rec) = astMark alg Nothing "RecCon" $
    fold alg rec
  fold alg (InfixCon a b) = astMark alg Nothing "InfixCon" $
    fold alg [a, b]

instance FoldId id => Fold (LTyClDecl id) where
  fold alg (L span _decl@(ForeignType {})) = astUnsupported alg (Just span) "ForeignType"
  fold alg (L span (FamDecl tcdFam)) = astMark alg (Just span) "FamDecl" $ do
    fold alg (L span tcdFam)
  fold alg (L span (SynDecl tcdLName
                            tcdTyVars
                            tcdRhs
                           _tcdFVs)) = astMark alg (Just span) "SynDecl" $ do
    foldId alg tcdLName DefSite
    fold alg tcdTyVars
    fold alg tcdRhs
  fold alg (L span (DataDecl tcdLName
                             tcdTyVars
                             tcdDataDefn
                            _tcdFVs)) = astMark alg (Just span) "DataDecl" $ do
    foldId alg tcdLName DefSite
    fold alg tcdTyVars
    fold alg tcdDataDefn
  fold alg (L span decl@(ClassDecl {})) = astMark alg (Just span) "ClassDecl" $ do
    fold alg (tcdCtxt decl)
    foldId alg (tcdLName decl) DefSite
    fold alg (tcdTyVars decl)
    -- Sadly, we don't get location info for the functional dependencies
    fold alg (tcdSigs decl)
    fold alg (tcdMeths decl)
    fold alg (tcdATs decl)
    fold alg (tcdATDefs decl)
    fold alg (tcdDocs decl)

instance FoldId id => Fold (LConDecl id) where
  fold alg (L span decl@(ConDecl {})) = astMark alg (Just span) "ConDecl" $ do
    foldId alg (con_name decl) DefSite
    fold alg (con_qvars decl)
    fold alg (con_cxt decl)
    fold alg (con_details decl)
    fold alg (con_res decl)

instance Fold ty => Fold (ResType ty) where
  fold alg ResTyH98 = astMark alg Nothing "ResTyH98" $ do
    return Nothing -- Nothing to do
  fold alg (ResTyGADT ty) = astMark alg Nothing "ResTyGADT" $ do
    fold alg ty

instance FoldId id => Fold (ConDeclField id) where
  fold alg (ConDeclField name typ _doc) = do
    foldId alg name DefSite
    fold alg typ

instance FoldId id => Fold (LInstDecl id) where
  fold alg (L span (ClsInstD cid_inst)) = astMark alg (Just span) "ClsInstD" $
    fold alg cid_inst
  fold alg (L span (DataFamInstD dfid_inst)) = astMark alg (Just span) "DataFamInstD" $
    fold alg dfid_inst
  fold alg (L span (TyFamInstD tfid_inst)) = astMark alg (Just span) "TyFamInstD" $
    fold alg tfid_inst

instance FoldId id => Fold (LDerivDecl id) where
  fold alg (L span (DerivDecl deriv_type)) = astMark alg (Just span) "LDerivDecl" $ do
    fold alg deriv_type

instance FoldId id => Fold (LFixitySig id) where
  fold alg (L span (FixitySig name _fixity)) = astMark alg (Just span) "LFixitySig" $ do
    foldId alg name SigSite

instance FoldId id => Fold (LDefaultDecl id) where
  fold alg (L span (DefaultDecl typs)) = astMark alg (Just span) "LDefaultDecl" $ do
    fold alg typs

instance FoldId id => Fold (LForeignDecl id) where
  fold alg (L span (ForeignImport name sig _coercion _import)) = astMark alg (Just span) "ForeignImport" $ do
    foldId alg name DefSite
    fold alg sig
  fold alg (L span (ForeignExport name sig _coercion _export)) = astMark alg (Just span) "ForeignExport" $ do
    foldId alg name UseSite
    fold alg sig

instance FoldId id => Fold (LWarnDecl id) where
  fold alg (L span (Warning name _txt)) = astMark alg (Just span) "Warning" $ do
    -- We use the span of the entire warning because we don't get location info for name
    foldId alg (L span name) UseSite

instance FoldId id => Fold (LAnnDecl id) where
  fold alg (L span _) = astUnsupported alg (Just span) "LAnnDecl"

instance FoldId id => Fold (LRuleDecl id) where
  fold alg (L span _) = astUnsupported alg (Just span) "LRuleDecl"

instance FoldId id => Fold (LVectDecl id) where
  fold alg (L span _) = astUnsupported alg (Just span) "LVectDecl"

instance Fold LDocDecl where
  fold alg (L span _) = astMark alg (Just span) "LDocDec" $
    -- Nothing to do
    return Nothing

instance FoldId id => Fold (Located (SpliceDecl id)) where
  fold alg (L span (SpliceDecl expr _explicit)) = astMark alg (Just span) "SpliceDecl" $ do
    fold alg expr

-- LHsDecl is a wrapper around the various kinds of declarations; the wrapped
-- declarations don't have location information of themselves, so we reuse
-- the location info of the wrapper
instance FoldId id => Fold (LHsDecl id) where
  fold alg (L span (TyClD tyClD)) = astMark alg (Just span) "TyClD" $
    fold alg (L span tyClD)
  fold alg (L span (InstD instD)) = astMark alg (Just span) "InstD" $
    fold alg (L span instD)
  fold alg (L span (DerivD derivD)) = astMark alg (Just span) "DerivD" $
    fold alg (L span derivD)
  fold alg (L span (ValD valD)) = astMark alg (Just span) "ValD" $
    fold alg (L span valD)
  fold alg (L span (SigD sigD)) = astMark alg (Just span) "SigD" $
    fold alg (L span sigD)
  fold alg (L span (DefD defD)) = astMark alg (Just span) "DefD" $
    fold alg (L span defD)
  fold alg (L span (ForD forD)) = astMark alg (Just span) "ForD" $
    fold alg (L span forD)
  fold alg (L span (WarningD warningD)) = astMark alg (Just span) "WarningD" $
    fold alg (L span warningD)
  fold alg (L span (AnnD annD)) = astMark alg (Just span) "AnnD" $
    fold alg (L span annD)
  fold alg (L span (RuleD ruleD)) = astMark alg (Just span) "RuleD" $
    fold alg (L span ruleD)
  fold alg (L span (VectD vectD)) = astMark alg (Just span) "VectD" $
    fold alg (L span vectD)
  fold alg (L span (SpliceD spliceD)) = astMark alg (Just span) "SpliceD" $
    fold alg (L span spliceD)
  fold alg (L span (DocD docD)) = astMark alg (Just span) "DocD" $
    fold alg (L span docD)
  fold alg (L span (QuasiQuoteD quasiQuoteD)) = astMark alg (Just span) "QuasiQuoteD" $
    fold alg (L span quasiQuoteD)
  fold alg (L span (RoleAnnotD _roleAnnotDecl)) = astMark alg (Just span) "RoleAnnotD" $
    -- TODO: Do something with roleAnnotDecl
    return Nothing

instance FoldId id => Fold (TyClGroup id) where
  fold alg (TyClGroup decls _roles) = astMark alg Nothing "TyClGroup" $
    -- TODO: deal with roles
    fold alg decls

instance FoldId id => Fold (LHsTyVarBndrs id) where
  fold alg (HsQTvs _hsq_kvs hsq_tvs) = astMark alg Nothing "HsQTvs" $ do
    -- TODO: sadly, we get no location information about the kind variables
    fold alg hsq_tvs

instance Fold (LHsCmd id) where
  -- TODO: support arrows
  fold _ _ = return Nothing

instance Fold thing => Fold (HsWithBndrs thing) where
  fold alg (HsWB hswb_cts _hswb_kvs _hswb_tvs) = astMark alg Nothing "HsWB" $ do
    -- TODO: sadly, we get no location information about the variables
    fold alg hswb_cts

instance FoldId id => Fold (LFamilyDecl id) where
  fold alg (L span (FamilyDecl fdInfo fdLName fdTyVars fdKindSig)) = astMark alg (Just span) "FamilyDecl" $ do
    fold alg fdInfo
    foldId alg fdLName DefSite
    fold alg fdTyVars
    fold alg fdKindSig

instance FoldId id => Fold (FamilyInfo id) where
  fold alg DataFamily = astMark alg Nothing "DataFamily" $
    return Nothing
  fold alg OpenTypeFamily = astMark alg Nothing "OpenTypeFamily" $
    return Nothing
  fold alg (ClosedTypeFamily instDecls) = astMark alg Nothing "ClosedTypeFamily" $
    fold alg instDecls

instance FoldId id => Fold (LTyFamInstDecl id) where
  fold alg (L span (TyFamInstDecl tfid_eqn _tfid_fvs)) = astMark alg (Just span) "TyFamInstDecl" $ do
    -- TODO: sadly, tfid_fvs is unlocated
    fold alg tfid_eqn

instance FoldId id => Fold (ClsInstDecl id) where
  fold alg (ClsInstDecl cid_poly_ty
                        cid_binds
                        cid_sigs
                        cid_tyfam_insts
                        cid_datafam_insts) = astMark alg Nothing "ClsInstDecl" $ do
    fold alg cid_poly_ty
    fold alg cid_binds
    fold alg cid_sigs
    fold alg cid_tyfam_insts
    fold alg cid_datafam_insts

instance FoldId id => Fold (DataFamInstDecl id) where
  fold alg (DataFamInstDecl dfid_tycon
                            dfid_pats
                            dfid_defn
                            _dfid_fvs) = astMark alg Nothing "DataFamInstDecl" $ do
    -- TODO: _dfid_fvs is unlocated
    foldId alg dfid_tycon UseSite
    fold alg dfid_pats
    fold alg dfid_defn

instance FoldId id => Fold (TyFamInstDecl id) where
  fold alg (TyFamInstDecl tfid_eqn _tfid_fvs) = astMark alg Nothing "TyFamInstDecl" $ do
    -- TODO: tfid_fvs is not located
    fold alg tfid_eqn

instance FoldId id => Fold (LTyFamInstEqn id) where
  fold alg (L span (TyFamInstEqn tfie_tycon
                                 tfie_pats
                                 tfie_rhs)) = astMark alg (Just span) "TyFamInstEqn" $ do
    foldId alg tfie_tycon UseSite
    fold alg tfie_pats
    fold alg tfie_rhs

instance FoldId id => Fold (LDataFamInstDecl id) where
  fold alg (L span (DataFamInstDecl dfid_tycon
                                    dfid_pats
                                    dfid_defn
                                   _dfid_fvs)) = astMark alg (Just span) "DataFamInstDecl" $ do
    -- TODO: dfid_fvs is not located
    foldId alg dfid_tycon UseSite
    fold alg dfid_pats
    fold alg dfid_defn

instance FoldId id => Fold (HsDataDefn id) where
  fold alg (HsDataDefn _dd_ND
                        dd_ctxt
                       _dd_cType
                        dd_kindSig
                        dd_cons
                        dd_derivs) = astMark alg Nothing "HsDataDefn" $ do
    fold alg dd_ctxt
    fold alg dd_kindSig
    fold alg dd_cons
    fold alg dd_derivs

{------------------------------------------------------------------------------
  Operations on types
------------------------------------------------------------------------------}

applyWrapper :: HsWrapper -> Type -> Type
applyWrapper WpHole            t = t -- identity
applyWrapper (WpTyApp t')      t = applyTy t t'
applyWrapper (WpEvApp _)       t = funRes1 t
applyWrapper (WpCompose w1 w2) t = applyWrapper w1 . applyWrapper w2 $ t
applyWrapper (WpCast coercion) _ = let Pair _ t = tcCoercionKind coercion in t
applyWrapper (WpTyLam v)       t = mkForAllTy v t
applyWrapper (WpEvLam v)       t = mkFunTy (evVarPred v) t
applyWrapper (WpLet _)         t = t -- we don't care about evidence _terms_

-- | Given @a -> b@, return @b@
funRes1 :: Type -> Type
funRes1 = snd . splitFunTy

-- | Given @a1 -> a2 -> b@, return @b@
funRes2 :: Type -> Type
funRes2 = funRes1 . funRes1

-- | Given @a1 -> a2 -> ... -> b@, return @b@
funResN :: Type -> Type
funResN = snd . splitFunTys

-- | Given @a -> b -> c@, return @(a, b, c)@
splitFunTy2 :: Type -> (Type, Type, Type)
splitFunTy2 ty0 = let (arg1, ty1) = splitFunTy ty0
                      (arg2, ty2) = splitFunTy ty1
                  in (arg1, arg2, ty2)

typeOfTyThing :: TyThing -> Maybe Type
typeOfTyThing (AConLike (RealDataCon dataCon)) = Just $ dataConRepType dataCon
typeOfTyThing _ = Nothing  -- we probably don't want psOrigResTy from PatSynCon
