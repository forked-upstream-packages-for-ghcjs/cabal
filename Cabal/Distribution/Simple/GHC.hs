-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.Simple.GHC
-- Copyright   :  Isaac Jones 2003-2007
-- License     :  BSD3
--
-- Maintainer  :  cabal-devel@haskell.org
-- Portability :  portable
--
-- This is a fairly large module. It contains most of the GHC-specific code for
-- configuring, building and installing packages. It also exports a function
-- for finding out what packages are already installed. Configuring involves
-- finding the @ghc@ and @ghc-pkg@ programs, finding what language extensions
-- this version of ghc supports and returning a 'Compiler' value.
--
-- 'getInstalledPackages' involves calling the @ghc-pkg@ program to find out
-- what packages are installed.
--
-- Building is somewhat complex as there is quite a bit of information to take
-- into account. We have to build libs and programs, possibly for profiling and
-- shared libs. We have to support building libraries that will be usable by
-- GHCi and also ghc's @-split-objs@ feature. We have to compile any C files
-- using ghc. Linking, especially for @split-objs@ is remarkably complex,
-- partly because there tend to be 1,000's of @.o@ files and this can often be
-- more than we can pass to the @ld@ or @ar@ programs in one go.
--
-- Installing for libs and exes involves finding the right files and copying
-- them to the right places. One of the more tricky things about this module is
-- remembering the layout of files in the build directory (which is not
-- explicitly documented) and thus what search dirs are used for various kinds
-- of files.

module Distribution.Simple.GHC (
        getGhcInfo,
        configure, getInstalledPackages, getPackageDBContents,
        buildLib, buildExe,
        replLib, replExe,
        startInterpreter,
        installLib, installExe,
        libAbiHash,
        initPackageDB,
        invokeHcPkg,
        registerPackage,
        componentGhcOptions,
        ghcLibDir,
        ghcDynamic,
        ghcGlobalPackageDB
 ) where

import Distribution.Simple.GHC.Props ( getImplProps, ghcVersionImplProps )
import qualified Distribution.Simple.GHC.Internal as Internal
import qualified Distribution.Simple.GHC.IPI641 as IPI641
import qualified Distribution.Simple.GHC.IPI642 as IPI642
import Distribution.PackageDescription as PD
         ( PackageDescription(..), BuildInfo(..), Executable(..)
         , Library(..), libModules, exeModules
         , hcOptions, hcProfOptions, hcSharedOptions
         , usedExtensions, allExtensions )
import Distribution.InstalledPackageInfo
         ( InstalledPackageInfo )
import qualified Distribution.InstalledPackageInfo as InstalledPackageInfo
                                ( InstalledPackageInfo_(..) )
import Distribution.Simple.PackageIndex (InstalledPackageIndex)
import qualified Distribution.Simple.PackageIndex as PackageIndex
import Distribution.Simple.LocalBuildInfo
         ( LocalBuildInfo(..), ComponentLocalBuildInfo(..)
         , LibraryName(..), absoluteInstallDirs )
import qualified Distribution.Simple.Hpc as Hpc
import Distribution.Simple.InstallDirs hiding ( absoluteInstallDirs )
import Distribution.Simple.BuildPaths
import Distribution.Simple.Utils
import Distribution.Package
         ( PackageName(..), InstalledPackageId, PackageId )
import qualified Distribution.ModuleName as ModuleName
import Distribution.Simple.Program
         ( Program(..), ConfiguredProgram(..), ProgramConfiguration
         , ProgramSearchPath
         , rawSystemProgram
         , rawSystemProgramStdout, rawSystemProgramStdoutConf
         , getProgramInvocationOutput, suppressOverrideArgs
         , requireProgramVersion, requireProgram
         , userMaybeSpecifyPath, programPath, lookupProgram, addKnownProgram
         , ghcProgram, ghcPkgProgram, hsc2hsProgram
         , arProgram, ldProgram
         , gccProgram, stripProgram )
import qualified Distribution.Simple.Program.HcPkg as HcPkg
import qualified Distribution.Simple.Program.Ar    as Ar
import qualified Distribution.Simple.Program.Ld    as Ld
import qualified Distribution.Simple.Program.Strip as Strip
import Distribution.Simple.Program.GHC
import Distribution.Simple.Setup
         ( toFlag, fromFlag, fromFlagOrDefault, configCoverage, configDistPref )
import qualified Distribution.Simple.Setup as Cabal
        ( Flag )
import Distribution.Simple.Compiler
         ( CompilerFlavor(..), CompilerId(..), Compiler(..), compilerVersion
         , OptimisationLevel(..), PackageDB(..), PackageDBStack )
import Distribution.Version
         ( Version(..), anyVersion, orLaterVersion )
import Distribution.System
         ( Platform(..), OS(..), buildOS, platformFromTriple )
import Distribution.Verbosity
import Distribution.Text
         ( display, simpleParse )
import Distribution.Utils.NubList
         ( overNubListR, toNubListR )
import Language.Haskell.Extension (Language(..), Extension(..)
                                  ,KnownExtension(..))

import Control.Monad            ( unless, when )
import Data.Char                ( isDigit, isSpace )
import Data.List
import qualified Data.Map as M  ( Map, fromList, lookup )
import Data.Maybe               ( catMaybes, fromMaybe, maybeToList )
import Data.Monoid              ( Monoid(..) )
import System.Directory
         ( getDirectoryContents, doesFileExist, getTemporaryDirectory )
import System.FilePath          ( (</>), (<.>), takeExtension,
                                  takeDirectory, replaceExtension,
                                  splitExtension )
import System.Environment (getEnv)
import Distribution.Compat.Exception (catchExit, catchIO)

-- -----------------------------------------------------------------------------
-- Configuring

configure :: Verbosity -> Maybe FilePath -> Maybe FilePath
          -> ProgramConfiguration
          -> IO (Compiler, Maybe Platform, ProgramConfiguration)
configure verbosity hcPath hcPkgPath conf0 = do

  (ghcProg, ghcVersion, conf1) <-
    requireProgramVersion verbosity ghcProgram
      (orLaterVersion (Version [6,4] []))
      (userMaybeSpecifyPath "ghc" hcPath conf0)
  let props = ghcVersionImplProps ghcVersion

  -- This is slightly tricky, we have to configure ghc first, then we use the
  -- location of ghc to help find ghc-pkg in the case that the user did not
  -- specify the location of ghc-pkg directly:
  (ghcPkgProg, ghcPkgVersion, conf2) <-
    requireProgramVersion verbosity ghcPkgProgram {
      programFindLocation = guessGhcPkgFromGhcPath ghcProg
    }
    anyVersion (userMaybeSpecifyPath "ghc-pkg" hcPkgPath conf1)

  when (ghcVersion /= ghcPkgVersion) $ die $
       "Version mismatch between ghc and ghc-pkg: "
    ++ programPath ghcProg ++ " is version " ++ display ghcVersion ++ " "
    ++ programPath ghcPkgProg ++ " is version " ++ display ghcPkgVersion

  -- Likewise we try to find the matching hsc2hs program.
  let hsc2hsProgram' = hsc2hsProgram {
                           programFindLocation = guessHsc2hsFromGhcPath ghcProg
                       }
      conf3 = addKnownProgram hsc2hsProgram' conf2

  languages  <- Internal.getLanguages verbosity props ghcProg
  extensions <- Internal.getExtensions verbosity props ghcProg

  ghcInfo <- Internal.getGhcInfo verbosity props ghcProg
  let ghcInfoMap = M.fromList ghcInfo

  let comp = Compiler {
        compilerId         = CompilerId GHC ghcVersion Nothing,
        compilerLanguages  = languages,
        compilerExtensions = extensions,
        compilerProperties = ghcInfoMap
      }
      compPlatform = Internal.targetPlatform ghcInfo
      conf4 = Internal.configureToolchain props ghcProg ghcInfoMap conf3 -- configure gcc and ld
  return (comp, compPlatform, conf4)

getGhcInfo :: Verbosity -> ConfiguredProgram -> IO [(String, String)]
getGhcInfo verbosity ghcProg = Internal.getGhcInfo verbosity props ghcProg
  where
    Just version = programVersion ghcProg
    props = ghcVersionImplProps version

-- | Given something like /usr/local/bin/ghc-6.6.1(.exe) we try and find
-- the corresponding tool; e.g. if the tool is ghc-pkg, we try looking
-- for a versioned or unversioned ghc-pkg in the same dir, that is:
--
-- > /usr/local/bin/ghc-pkg-ghc-6.6.1(.exe)
-- > /usr/local/bin/ghc-pkg-6.6.1(.exe)
-- > /usr/local/bin/ghc-pkg(.exe)
--
guessToolFromGhcPath :: Program -> ConfiguredProgram
                     -> Verbosity -> ProgramSearchPath
                     -> IO (Maybe FilePath)
guessToolFromGhcPath tool ghcProg verbosity searchpath
  = do let toolname          = programName tool
           path              = programPath ghcProg
           dir               = takeDirectory path
           versionSuffix     = takeVersionSuffix (dropExeExtension path)
           guessNormal       = dir </> toolname <.> exeExtension
           guessGhcVersioned = dir </> (toolname ++ "-ghc" ++ versionSuffix)
                               <.> exeExtension
           guessVersioned    = dir </> (toolname ++ versionSuffix)
                               <.> exeExtension
           guesses | null versionSuffix = [guessNormal]
                   | otherwise          = [guessGhcVersioned,
                                           guessVersioned,
                                           guessNormal]
       info verbosity $ "looking for tool " ++ toolname
         ++ " near compiler in " ++ dir
       exists <- mapM doesFileExist guesses
       case [ file | (file, True) <- zip guesses exists ] of
                   -- If we can't find it near ghc, fall back to the usual
                   -- method.
         []     -> programFindLocation tool verbosity searchpath
         (fp:_) -> do info verbosity $ "found " ++ toolname ++ " in " ++ fp
                      return (Just fp)

  where takeVersionSuffix :: FilePath -> String
        takeVersionSuffix = takeWhileEndLE isSuffixChar

        isSuffixChar :: Char -> Bool
        isSuffixChar c = isDigit c || c == '.' || c == '-'

        dropExeExtension :: FilePath -> FilePath
        dropExeExtension filepath =
          case splitExtension filepath of
            (filepath', extension) | extension == exeExtension -> filepath'
                                   | otherwise                 -> filepath

-- | Given something like /usr/local/bin/ghc-6.6.1(.exe) we try and find a
-- corresponding ghc-pkg, we try looking for both a versioned and unversioned
-- ghc-pkg in the same dir, that is:
--
-- > /usr/local/bin/ghc-pkg-ghc-6.6.1(.exe)
-- > /usr/local/bin/ghc-pkg-6.6.1(.exe)
-- > /usr/local/bin/ghc-pkg(.exe)
--
guessGhcPkgFromGhcPath :: ConfiguredProgram
                       -> Verbosity -> ProgramSearchPath -> IO (Maybe FilePath)
guessGhcPkgFromGhcPath = guessToolFromGhcPath ghcPkgProgram

-- | Given something like /usr/local/bin/ghc-6.6.1(.exe) we try and find a
-- corresponding hsc2hs, we try looking for both a versioned and unversioned
-- hsc2hs in the same dir, that is:
--
-- > /usr/local/bin/hsc2hs-ghc-6.6.1(.exe)
-- > /usr/local/bin/hsc2hs-6.6.1(.exe)
-- > /usr/local/bin/hsc2hs(.exe)
--
guessHsc2hsFromGhcPath :: ConfiguredProgram
                       -> Verbosity -> ProgramSearchPath -> IO (Maybe FilePath)
guessHsc2hsFromGhcPath = guessToolFromGhcPath hsc2hsProgram

-- | Given a single package DB, return all installed packages.
getPackageDBContents :: Verbosity -> PackageDB -> ProgramConfiguration
                        -> IO InstalledPackageIndex
getPackageDBContents verbosity packagedb conf = do
  pkgss <- getInstalledPackages' verbosity [packagedb] conf
  toPackageIndex verbosity pkgss conf

-- | Given a package DB stack, return all installed packages.
getInstalledPackages :: Verbosity -> PackageDBStack -> ProgramConfiguration
                     -> IO InstalledPackageIndex
getInstalledPackages verbosity packagedbs conf = do
  checkPackageDbEnvVar
  checkPackageDbStack packagedbs
  pkgss <- getInstalledPackages' verbosity packagedbs conf
  index <- toPackageIndex verbosity pkgss conf
  return $! hackRtsPackage index

  where
    hackRtsPackage index =
      case PackageIndex.lookupPackageName index (PackageName "rts") of
        [(_,[rts])]
           -> PackageIndex.insert (removeMingwIncludeDir rts) index
        _  -> index -- No (or multiple) ghc rts package is registered!!
                    -- Feh, whatever, the ghc test suite does some crazy stuff.

-- | Given a list of @(PackageDB, InstalledPackageInfo)@ pairs, produce a
-- @PackageIndex@. Helper function used by 'getPackageDBContents' and
-- 'getInstalledPackages'.
toPackageIndex :: Verbosity
               -> [(PackageDB, [InstalledPackageInfo])]
               -> ProgramConfiguration
               -> IO InstalledPackageIndex
toPackageIndex verbosity pkgss conf = do
  -- On Windows, various fields have $topdir/foo rather than full
  -- paths. We need to substitute the right value in so that when
  -- we, for example, call gcc, we have proper paths to give it.
  topDir <- ghcLibDir' verbosity ghcProg
  let indices = [ PackageIndex.fromList (map (substTopDir topDir) pkgs)
                | (_, pkgs) <- pkgss ]
  return $! (mconcat indices)

  where
    Just ghcProg = lookupProgram ghcProgram conf

ghcLibDir :: Verbosity -> LocalBuildInfo -> IO FilePath
ghcLibDir verbosity lbi =
    dropWhileEndLE isSpace `fmap`
     rawSystemProgramStdoutConf verbosity ghcProgram
     (withPrograms lbi) ["--print-libdir"]

ghcLibDir' :: Verbosity -> ConfiguredProgram -> IO FilePath
ghcLibDir' verbosity ghcProg =
    dropWhileEndLE isSpace `fmap`
     rawSystemProgramStdout verbosity ghcProg ["--print-libdir"]


-- | Return the 'FilePath' to the global GHC package database.
ghcGlobalPackageDB :: Verbosity -> ConfiguredProgram -> IO FilePath
ghcGlobalPackageDB verbosity ghcProg =
    dropWhileEndLE isSpace `fmap`
     rawSystemProgramStdout verbosity ghcProg ["--print-global-package-db"]

-- Cabal does not use the environment variable GHC_PACKAGE_PATH; let users
-- know that this is the case. See ticket #335. Simply ignoring it is not a
-- good idea, since then ghc and cabal are looking at different sets of
-- package DBs and chaos is likely to ensue.
checkPackageDbEnvVar :: IO ()
checkPackageDbEnvVar = do
    hasGPP <- (getEnv "GHC_PACKAGE_PATH" >> return True)
              `catchIO` (\_ -> return False)
    when hasGPP $
      die $ "Use of GHC's environment variable GHC_PACKAGE_PATH is "
         ++ "incompatible with Cabal. Use the flag --package-db to specify a "
         ++ "package database (it can be used multiple times)."

checkPackageDbStack :: PackageDBStack -> IO ()
checkPackageDbStack (GlobalPackageDB:rest)
  | GlobalPackageDB `notElem` rest = return ()
checkPackageDbStack rest
  | GlobalPackageDB `notElem` rest =
  die $ "With current ghc versions the global package db is always used "
     ++ "and must be listed first. This ghc limitation may be lifted in "
     ++ "future, see http://hackage.haskell.org/trac/ghc/ticket/5977"
checkPackageDbStack _ =
  die $ "If the global package db is specified, it must be "
     ++ "specified first and cannot be specified multiple times"

-- GHC < 6.10 put "$topdir/include/mingw" in rts's installDirs. This
-- breaks when you want to use a different gcc, so we need to filter
-- it out.
removeMingwIncludeDir :: InstalledPackageInfo -> InstalledPackageInfo
removeMingwIncludeDir pkg =
    let ids = InstalledPackageInfo.includeDirs pkg
        ids' = filter (not . ("mingw" `isSuffixOf`)) ids
    in pkg { InstalledPackageInfo.includeDirs = ids' }

-- | Get the packages from specific PackageDBs, not cumulative.
--
getInstalledPackages' :: Verbosity -> [PackageDB] -> ProgramConfiguration
                     -> IO [(PackageDB, [InstalledPackageInfo])]
getInstalledPackages' verbosity packagedbs conf
  | ghcVersion >= Version [6,9] [] =
  sequence
    [ do pkgs <- HcPkg.dump verbosity (ghcVersionImplProps ghcVersion)
                   ghcPkgProg packagedb
         return (packagedb, pkgs)
    | packagedb <- packagedbs ]

  where
    Just ghcPkgProg = lookupProgram ghcPkgProgram conf
    Just ghcProg    = lookupProgram ghcProgram conf
    Just ghcVersion = programVersion ghcProg

getInstalledPackages' verbosity packagedbs conf = do
    str <- rawSystemProgramStdoutConf verbosity ghcPkgProgram conf ["list"]
    let pkgFiles = [ init line | line <- lines str, last line == ':' ]
        dbFile packagedb = case (packagedb, pkgFiles) of
          (GlobalPackageDB, global:_)      -> return $ Just global
          (UserPackageDB,  _global:user:_) -> return $ Just user
          (UserPackageDB,  _global:_)      -> return $ Nothing
          (SpecificPackageDB specific, _)  -> return $ Just specific
          _ -> die "cannot read ghc-pkg package listing"
    pkgFiles' <- mapM dbFile packagedbs
    sequence [ withFileContents file $ \content -> do
                  pkgs <- readPackages file content
                  return (db, pkgs)
             | (db , Just file) <- zip packagedbs pkgFiles' ]
  where
    -- Depending on the version of ghc we use a different type's Read
    -- instance to parse the package file and then convert.
    -- It's a bit yuck. But that's what we get for using Read/Show.
    readPackages
      | ghcVersion >= Version [6,4,2] []
      = \file content -> case reads content of
          [(pkgs, _)] -> return (map IPI642.toCurrent pkgs)
          _           -> failToRead file
      | otherwise
      = \file content -> case reads content of
          [(pkgs, _)] -> return (map IPI641.toCurrent pkgs)
          _           -> failToRead file
    Just ghcProg = lookupProgram ghcProgram conf
    Just ghcVersion = programVersion ghcProg
    failToRead file = die $ "cannot read ghc package database " ++ file

substTopDir :: FilePath -> InstalledPackageInfo -> InstalledPackageInfo
substTopDir topDir ipo
 = ipo {
       InstalledPackageInfo.importDirs
           = map f (InstalledPackageInfo.importDirs ipo),
       InstalledPackageInfo.libraryDirs
           = map f (InstalledPackageInfo.libraryDirs ipo),
       InstalledPackageInfo.includeDirs
           = map f (InstalledPackageInfo.includeDirs ipo),
       InstalledPackageInfo.frameworkDirs
           = map f (InstalledPackageInfo.frameworkDirs ipo),
       InstalledPackageInfo.haddockInterfaces
           = map f (InstalledPackageInfo.haddockInterfaces ipo),
       InstalledPackageInfo.haddockHTMLs
           = map f (InstalledPackageInfo.haddockHTMLs ipo)
   }
    where f ('$':'t':'o':'p':'d':'i':'r':rest) = topDir ++ rest
          f x = x

-- -----------------------------------------------------------------------------
-- Building

-- | Build a library with GHC.
--
buildLib, replLib :: Verbosity          -> Cabal.Flag (Maybe Int)
                  -> PackageDescription -> LocalBuildInfo
                  -> Library            -> ComponentLocalBuildInfo -> IO ()
buildLib = buildOrReplLib False
replLib  = buildOrReplLib True

buildOrReplLib :: Bool -> Verbosity  -> Cabal.Flag (Maybe Int)
               -> PackageDescription -> LocalBuildInfo
               -> Library            -> ComponentLocalBuildInfo -> IO ()
buildOrReplLib forRepl verbosity numJobsFlag pkg_descr lbi lib clbi = do
  libName <- case componentLibraries clbi of
             [libName] -> return libName
             [] -> die "No library name found when building library"
             _  -> die "Multiple library names found when building library"

  let libTargetDir = buildDir lbi
      numJobs = fromMaybe 1 $ fromFlagOrDefault Nothing numJobsFlag
      whenVanillaLib forceVanilla =
        when (forceVanilla || withVanillaLib lbi)
      whenProfLib = when (withProfLib lbi)
      whenSharedLib forceShared =
        when (forceShared || withSharedLib lbi)
      whenGHCiLib = when (withGHCiLib lbi && withVanillaLib lbi)
      ifReplLib = when forRepl
      comp = compiler lbi
      ghcVersion = compilerVersion comp
      props = getImplProps comp
      (Platform _hostArch hostOS) = hostPlatform lbi

  (ghcProg, _) <- requireProgram verbosity ghcProgram (withPrograms lbi)
  let runGhcProg = runGHC verbosity ghcProg comp

  libBi <- hackThreadedFlag verbosity
             comp (withProfLib lbi) (libBuildInfo lib)

  let isGhcDynamic        = ghcDynamic comp
      dynamicTooSupported = ghcSupportsDynamicToo comp
      doingTH = EnableExtension TemplateHaskell `elem` allExtensions libBi
      forceVanillaLib = doingTH && not isGhcDynamic
      forceSharedLib  = doingTH &&     isGhcDynamic
      -- TH always needs default libs, even when building for profiling

  -- Determine if program coverage should be enabled and if so, what
  -- '-hpcdir' should be.
  let isCoverageEnabled = fromFlag $ configCoverage $ configFlags lbi
      -- Component name. Not 'libName' because that has the "HS" prefix
      -- that GHC gives Haskell libraries.
      cname = display $ PD.package $ localPkgDescr lbi
      distPref = fromFlag $ configDistPref $ configFlags lbi
      hpcdir | isCoverageEnabled = toFlag $ Hpc.mixDir distPref cname
             | otherwise = mempty

  createDirectoryIfMissingVerbose verbosity True libTargetDir
  -- TODO: do we need to put hs-boot files into place for mutually recursive
  -- modules?
  let cObjs       = map (`replaceExtension` objExtension) (cSources libBi)
      baseOpts    = componentGhcOptions verbosity lbi libBi clbi libTargetDir
                    `mappend` mempty { ghcOptHPCDir = hpcdir }
      vanillaOpts = baseOpts `mappend` mempty {
                      ghcOptMode         = toFlag GhcModeMake,
                      ghcOptNumJobs      = toFlag numJobs,
                      ghcOptPackageKey   = toFlag (pkgKey lbi),
                      ghcOptInputModules = toNubListR $ libModules lib
                    }

      profOpts    = vanillaOpts `mappend` mempty {
                      ghcOptProfilingMode = toFlag True,
                      ghcOptHiSuffix      = toFlag "p_hi",
                      ghcOptObjSuffix     = toFlag "p_o",
                      ghcOptExtra         = toNubListR $ hcProfOptions GHC libBi
                    }

      sharedOpts  = vanillaOpts `mappend` mempty {
                      ghcOptDynLinkMode = toFlag GhcDynamicOnly,
                      ghcOptFPic        = toFlag True,
                      ghcOptHiSuffix    = toFlag "dyn_hi",
                      ghcOptObjSuffix   = toFlag "dyn_o",
                      ghcOptExtra       = toNubListR $ hcSharedOptions GHC libBi
                    }
      linkerOpts = mempty {
                      ghcOptLinkOptions    = toNubListR $ PD.ldOptions libBi,
                      ghcOptLinkLibs       = toNubListR $ extraLibs libBi,
                      ghcOptLinkLibPath    = toNubListR $ extraLibDirs libBi,
                      ghcOptLinkFrameworks = toNubListR $ PD.frameworks libBi,
                      ghcOptInputFiles     = toNubListR
                                             [libTargetDir </> x | x <- cObjs]
                   }
      replOpts    = vanillaOpts {
                      ghcOptExtra        = overNubListR
                                           Internal.filterGhciFlags $
                                           (ghcOptExtra vanillaOpts),
                      ghcOptNumJobs      = mempty
                    }
                    `mappend` linkerOpts
                    `mappend` mempty {
                      ghcOptMode         = toFlag GhcModeInteractive,
                      ghcOptOptimisation = toFlag GhcNoOptimisation
                    }

      vanillaSharedOpts = vanillaOpts `mappend` mempty {
                      ghcOptDynLinkMode  = toFlag GhcStaticAndDynamic,
                      ghcOptDynHiSuffix  = toFlag "dyn_hi",
                      ghcOptDynObjSuffix = toFlag "dyn_o"
                    }

  unless (forRepl || null (libModules lib)) $
    do let vanilla = whenVanillaLib forceVanillaLib (runGhcProg vanillaOpts)
           shared  = whenSharedLib  forceSharedLib  (runGhcProg sharedOpts)
           useDynToo = dynamicTooSupported &&
                       (forceVanillaLib || withVanillaLib lbi) &&
                       (forceSharedLib  || withSharedLib  lbi) &&
                       null (hcSharedOptions GHC libBi)
       if useDynToo
           then runGhcProg vanillaSharedOpts
           else if isGhcDynamic then do shared;  vanilla
                                else do vanilla; shared
       whenProfLib (runGhcProg profOpts)

  -- build any C sources
  unless (null (cSources libBi)) $ do
    info verbosity "Building C Sources..."
    sequence_
      [ do let vanillaCcOpts = (Internal.componentCcGhcOptions verbosity props
                                lbi libBi clbi libTargetDir filename)
               profCcOpts    = vanillaCcOpts `mappend` mempty {
                                 ghcOptProfilingMode = toFlag True,
                                 ghcOptObjSuffix     = toFlag "p_o"
                               }
               sharedCcOpts  = vanillaCcOpts `mappend` mempty {
                                 ghcOptFPic        = toFlag True,
                                 ghcOptDynLinkMode = toFlag GhcDynamicOnly,
                                 ghcOptObjSuffix   = toFlag "dyn_o"
                               }
               odir          = fromFlag (ghcOptObjDir vanillaCcOpts)
           createDirectoryIfMissingVerbose verbosity True odir
           runGhcProg vanillaCcOpts
           unless forRepl $
             whenSharedLib forceSharedLib (runGhcProg sharedCcOpts)
           unless forRepl $ whenProfLib (runGhcProg profCcOpts)
      | filename <- cSources libBi]


  -- TODO: problem here is we need the .c files built first, so we can load them
  -- with ghci, but .c files can depend on .h files generated by ghc by ffi
  -- exports.
  unless (null (libModules lib)) $
     ifReplLib (runGhcProg replOpts)

  -- link:
  unless forRepl $ do
    info verbosity "Linking..."
    let cProfObjs   = map (`replaceExtension` ("p_" ++ objExtension))
                      (cSources libBi)
        cSharedObjs = map (`replaceExtension` ("dyn_" ++ objExtension))
                      (cSources libBi)
        cid = compilerId (compiler lbi)
        vanillaLibFilePath = libTargetDir </> mkLibName           libName
        profileLibFilePath = libTargetDir </> mkProfLibName       libName
        sharedLibFilePath  = libTargetDir </> mkSharedLibName cid libName
        ghciLibFilePath    = libTargetDir </> Internal.mkGHCiLibName       libName
        libInstallPath = libdir $ absoluteInstallDirs pkg_descr lbi NoCopyDest
        sharedLibInstallPath = libInstallPath </> mkSharedLibName cid libName

    stubObjs <- fmap catMaybes $ sequence
      [ findFileWithExtension [objExtension] [libTargetDir]
          (ModuleName.toFilePath x ++"_stub")
      | ghcVersion < Version [7,2] [] -- ghc-7.2+ does not make _stub.o files
      , x <- libModules lib ]
    stubProfObjs <- fmap catMaybes $ sequence
      [ findFileWithExtension ["p_" ++ objExtension] [libTargetDir]
          (ModuleName.toFilePath x ++"_stub")
      | ghcVersion < Version [7,2] [] -- ghc-7.2+ does not make _stub.o files
      , x <- libModules lib ]
    stubSharedObjs <- fmap catMaybes $ sequence
      [ findFileWithExtension ["dyn_" ++ objExtension] [libTargetDir]
          (ModuleName.toFilePath x ++"_stub")
      | ghcVersion < Version [7,2] [] -- ghc-7.2+ does not make _stub.o files
      , x <- libModules lib ]

    hObjs     <- Internal.getHaskellObjects props lib lbi
                      libTargetDir objExtension True
    hProfObjs <-
      if (withProfLib lbi)
              then Internal.getHaskellObjects props lib lbi
                      libTargetDir ("p_" ++ objExtension) True
              else return []
    hSharedObjs <-
      if (withSharedLib lbi)
              then Internal.getHaskellObjects props lib lbi
                      libTargetDir ("dyn_" ++ objExtension) False
              else return []

    unless (null hObjs && null cObjs && null stubObjs) $ do

      let staticObjectFiles =
                 hObjs
              ++ map (libTargetDir </>) cObjs
              ++ stubObjs
          profObjectFiles =
                 hProfObjs
              ++ map (libTargetDir </>) cProfObjs
              ++ stubProfObjs
          ghciObjFiles =
                 hObjs
              ++ map (libTargetDir </>) cObjs
              ++ stubObjs
          dynamicObjectFiles =
                 hSharedObjs
              ++ map (libTargetDir </>) cSharedObjs
              ++ stubSharedObjs
          -- After the relocation lib is created we invoke ghc -shared
          -- with the dependencies spelled out as -package arguments
          -- and ghc invokes the linker with the proper library paths
          ghcSharedLinkArgs =
              mempty {
                ghcOptShared             = toFlag True,
                ghcOptDynLinkMode        = toFlag GhcDynamicOnly,
                ghcOptInputFiles         = toNubListR dynamicObjectFiles,
                ghcOptOutputFile         = toFlag sharedLibFilePath,
                -- For dynamic libs, Mac OS/X needs to know the install location
                -- at build time. This only applies to GHC < 7.8 - see the
                -- discussion in #1660.
                ghcOptDylibName          = if (hostOS == OSX
                                               && ghcVersion < Version [7,8] [])
                                            then toFlag sharedLibInstallPath
                                            else mempty,
                ghcOptPackageKey         = toFlag (pkgKey lbi),
                ghcOptNoAutoLinkPackages = toFlag True,
                ghcOptPackageDBs         = withPackageDB lbi,
                ghcOptPackages           = toNubListR $
                                           Internal.mkGhcOptPackages clbi ,
                ghcOptLinkLibs           = toNubListR $ extraLibs libBi,
                ghcOptLinkLibPath        = toNubListR $ extraLibDirs libBi
              }

      whenVanillaLib False $ do
        Ar.createArLibArchive verbosity lbi vanillaLibFilePath staticObjectFiles

      whenProfLib $ do
        Ar.createArLibArchive verbosity lbi profileLibFilePath profObjectFiles

      whenGHCiLib $ do
        (ldProg, _) <- requireProgram verbosity ldProgram (withPrograms lbi)
        Ld.combineObjectFiles verbosity ldProg
          ghciLibFilePath ghciObjFiles

      whenSharedLib False $
        runGhcProg ghcSharedLinkArgs

-- | Start a REPL without loading any source files.
startInterpreter :: Verbosity -> ProgramConfiguration -> Compiler
                 -> PackageDBStack -> IO ()
startInterpreter verbosity conf comp packageDBs = do
  let replOpts = mempty {
        ghcOptMode       = toFlag GhcModeInteractive,
        ghcOptPackageDBs = packageDBs
        }
  checkPackageDbStack packageDBs
  (ghcProg, _) <- requireProgram verbosity ghcProgram conf
  runGHC verbosity ghcProg comp replOpts

-- | Build an executable with GHC.
--
buildExe, replExe :: Verbosity          -> Cabal.Flag (Maybe Int)
                  -> PackageDescription -> LocalBuildInfo
                  -> Executable         -> ComponentLocalBuildInfo -> IO ()
buildExe = buildOrReplExe False
replExe  = buildOrReplExe True

buildOrReplExe :: Bool
               -> Verbosity          -> Cabal.Flag (Maybe Int)
               -> PackageDescription -> LocalBuildInfo
               -> Executable         -> ComponentLocalBuildInfo -> IO ()
buildOrReplExe forRepl verbosity numJobsFlag _pkg_descr lbi
  exe@Executable { exeName = exeName', modulePath = modPath } clbi = do

  (ghcProg, _) <- requireProgram verbosity ghcProgram (withPrograms lbi)
  let comp       = compiler lbi
      props      = getImplProps comp
      numJobs    = fromMaybe 1 $
                   fromFlagOrDefault Nothing numJobsFlag
      runGhcProg = runGHC verbosity ghcProg comp

  exeBi <- hackThreadedFlag verbosity
             comp (withProfExe lbi) (buildInfo exe)

  -- exeNameReal, the name that GHC really uses (with .exe on Windows)
  let exeNameReal = exeName' <.>
                    (if takeExtension exeName' /= ('.':exeExtension)
                       then exeExtension
                       else "")

  let targetDir = (buildDir lbi) </> exeName'
  let exeDir    = targetDir </> (exeName' ++ "-tmp")
  createDirectoryIfMissingVerbose verbosity True targetDir
  createDirectoryIfMissingVerbose verbosity True exeDir
  -- TODO: do we need to put hs-boot files into place for mutually recursive
  -- modules?  FIX: what about exeName.hi-boot?

  -- Determine if program coverage should be enabled and if so, what
  -- '-hpcdir' should be.
  let isCoverageEnabled = fromFlag $ configCoverage $ configFlags lbi
      distPref = fromFlag $ configDistPref $ configFlags lbi
      hpcdir | isCoverageEnabled = toFlag $ Hpc.mixDir distPref exeName'
             | otherwise = mempty

  -- build executables

  srcMainFile         <- findFile (exeDir : hsSourceDirs exeBi) modPath
  let isGhcDynamic        = ghcDynamic comp
      dynamicTooSupported = ghcSupportsDynamicToo comp
      isHaskellMain = elem (takeExtension srcMainFile) [".hs", ".lhs"]
      cSrcs         = cSources exeBi ++ [srcMainFile | not isHaskellMain]
      cObjs         = map (`replaceExtension` objExtension) cSrcs
      baseOpts   = (componentGhcOptions verbosity lbi exeBi clbi exeDir)
                    `mappend` mempty {
                      ghcOptMode         = toFlag GhcModeMake,
                      ghcOptInputFiles   = toNubListR
                        [ srcMainFile | isHaskellMain],
                      ghcOptInputModules = toNubListR
                        [ m | not isHaskellMain, m <- exeModules exe],
                      ghcOptHPCDir = hpcdir
                    }
      staticOpts = baseOpts `mappend` mempty {
                      ghcOptDynLinkMode    = toFlag GhcStaticOnly
                   }
      profOpts   = baseOpts `mappend` mempty {
                      ghcOptProfilingMode  = toFlag True,
                      ghcOptHiSuffix       = toFlag "p_hi",
                      ghcOptObjSuffix      = toFlag "p_o",
                      ghcOptExtra          = toNubListR $ hcProfOptions GHC exeBi
                    }
      dynOpts    = baseOpts `mappend` mempty {
                      ghcOptDynLinkMode    = toFlag GhcDynamicOnly,
                      ghcOptHiSuffix       = toFlag "dyn_hi",
                      ghcOptObjSuffix      = toFlag "dyn_o",
                      ghcOptExtra          = toNubListR $
                                             hcSharedOptions GHC exeBi
                    }
      dynTooOpts = staticOpts `mappend` mempty {
                      ghcOptDynLinkMode    = toFlag GhcStaticAndDynamic,
                      ghcOptDynHiSuffix    = toFlag "dyn_hi",
                      ghcOptDynObjSuffix   = toFlag "dyn_o"
                    }
      linkerOpts = mempty {
                      ghcOptLinkOptions    = toNubListR $ PD.ldOptions exeBi,
                      ghcOptLinkLibs       = toNubListR $ extraLibs exeBi,
                      ghcOptLinkLibPath    = toNubListR $ extraLibDirs exeBi,
                      ghcOptLinkFrameworks = toNubListR $ PD.frameworks exeBi,
                      ghcOptInputFiles     = toNubListR
                                             [exeDir </> x | x <- cObjs]
                   }
      replOpts   = baseOpts {
                      ghcOptExtra          = overNubListR
                                             Internal.filterGhciFlags
                                             (ghcOptExtra baseOpts)
                   }
                   -- For a normal compile we do separate invocations of ghc for
                   -- compiling as for linking. But for repl we have to do just
                   -- the one invocation, so that one has to include all the
                   -- linker stuff too, like -l flags and any .o files from C
                   -- files etc.
                   `mappend` linkerOpts
                   `mappend` mempty {
                      ghcOptMode           = toFlag GhcModeInteractive,
                      ghcOptOptimisation   = toFlag GhcNoOptimisation
                   }
      commonOpts  | withProfExe lbi = profOpts
                  | withDynExe  lbi = dynOpts
                  | otherwise       = staticOpts
      compileOpts | useDynToo = dynTooOpts
                  | otherwise = commonOpts
      withStaticExe = (not $ withProfExe lbi) && (not $ withDynExe lbi)

      -- For building exe's that use TH with -prof or -dynamic we actually have
      -- to build twice, once without -prof/-dynamic and then again with
      -- -prof/-dynamic. This is because the code that TH needs to run at
      -- compile time needs to be the vanilla ABI so it can be loaded up and run
      -- by the compiler.
      -- With dynamic-by-default GHC the TH object files loaded at compile-time
      -- need to be .dyn_o instead of .o.
      doingTH = EnableExtension TemplateHaskell `elem` allExtensions exeBi
      -- Should we use -dynamic-too instead of compiling twice?
      useDynToo = dynamicTooSupported && isGhcDynamic
                  && doingTH && withStaticExe
                  && null (hcSharedOptions GHC exeBi)
      compileTHOpts | isGhcDynamic = dynOpts
                    | otherwise    = staticOpts
      compileForTH
        | forRepl      = False
        | useDynToo    = False
        | isGhcDynamic = doingTH && (withProfExe lbi || withStaticExe)
        | otherwise    = doingTH && (withProfExe lbi || withDynExe lbi)

      linkOpts = commonOpts `mappend`
                 linkerOpts `mappend` mempty {
                      ghcOptLinkNoHsMain   = toFlag (not isHaskellMain)
                 }

  -- Build static/dynamic object files for TH, if needed.
  when compileForTH $
    runGhcProg compileTHOpts { ghcOptNoLink  = toFlag True
                             , ghcOptNumJobs = toFlag numJobs }

  unless forRepl $
    runGhcProg compileOpts { ghcOptNoLink  = toFlag True
                           , ghcOptNumJobs = toFlag numJobs }

  -- build any C sources
  unless (null cSrcs) $ do
   info verbosity "Building C Sources..."
   sequence_
     [ do let opts = (Internal.componentCcGhcOptions verbosity props lbi exeBi
                         clbi exeDir filename) `mappend` mempty {
                       ghcOptDynLinkMode   = toFlag (if withDynExe lbi
                                                       then GhcDynamicOnly
                                                       else GhcStaticOnly),
                       ghcOptProfilingMode = toFlag (withProfExe lbi)
                     }
              odir = fromFlag (ghcOptObjDir opts)
          createDirectoryIfMissingVerbose verbosity True odir
          runGhcProg opts
     | filename <- cSrcs ]

  -- TODO: problem here is we need the .c files built first, so we can load them
  -- with ghci, but .c files can depend on .h files generated by ghc by ffi
  -- exports.
  when forRepl $ runGhcProg replOpts

  -- link:
  unless forRepl $ do
    info verbosity "Linking..."
    runGhcProg linkOpts { ghcOptOutputFile = toFlag (targetDir </> exeNameReal) }


-- | Filter the "-threaded" flag when profiling as it does not
--   work with ghc-6.8 and older.
hackThreadedFlag :: Verbosity -> Compiler -> Bool -> BuildInfo -> IO BuildInfo
hackThreadedFlag verbosity comp prof bi
  | not mustFilterThreaded = return bi
  | otherwise              = do
    warn verbosity $ "The ghc flag '-threaded' is not compatible with "
                  ++ "profiling in ghc-6.8 and older. It will be disabled."
    return bi { options = filterHcOptions (/= "-threaded") (options bi) }
  where
    mustFilterThreaded = prof && compilerVersion comp < Version [6, 10] []
                      && "-threaded" `elem` hcOptions GHC bi
    filterHcOptions p hcoptss =
      [ (hc, if hc == GHC then filter p opts else opts)
      | (hc, opts) <- hcoptss ]

-- | Extracts a String representing a hash of the ABI of a built
-- library.  It can fail if the library has not yet been built.
--
libAbiHash :: Verbosity -> PackageDescription -> LocalBuildInfo
           -> Library -> ComponentLocalBuildInfo -> IO String
libAbiHash verbosity _pkg_descr lbi lib clbi = do
  libBi <- hackThreadedFlag verbosity
             (compiler lbi) (withProfLib lbi) (libBuildInfo lib)
  let
      comp        = compiler lbi
      props       = getImplProps comp
      vanillaArgs =
        (componentGhcOptions verbosity lbi libBi clbi (buildDir lbi))
        `mappend` mempty {
          ghcOptMode         = toFlag GhcModeAbiHash,
          ghcOptPackageKey   = toFlag (pkgKey lbi),
          ghcOptInputModules = toNubListR $ exposedModules lib
        }
      sharedArgs = vanillaArgs `mappend` mempty {
                       ghcOptDynLinkMode = toFlag GhcDynamicOnly,
                       ghcOptFPic        = toFlag True,
                       ghcOptHiSuffix    = toFlag "dyn_hi",
                       ghcOptObjSuffix   = toFlag "dyn_o",
                       ghcOptExtra       = toNubListR $ hcSharedOptions GHC libBi
                   }
      profArgs = vanillaArgs `mappend` mempty {
                     ghcOptProfilingMode = toFlag True,
                     ghcOptHiSuffix      = toFlag "p_hi",
                     ghcOptObjSuffix     = toFlag "p_o",
                     ghcOptExtra         = toNubListR $ hcProfOptions GHC libBi
                 }
      ghcArgs = if withVanillaLib lbi then vanillaArgs
           else if withSharedLib  lbi then sharedArgs
           else if withProfLib    lbi then profArgs
           else error "libAbiHash: Can't find an enabled library way"
  --
  (ghcProg, _) <- requireProgram verbosity ghcProgram (withPrograms lbi)
  hash <- getProgramInvocationOutput verbosity (ghcInvocation ghcProg comp ghcArgs)
  return (takeWhile (not . isSpace) hash)

componentGhcOptions :: Verbosity -> LocalBuildInfo
                    -> BuildInfo -> ComponentLocalBuildInfo -> FilePath
                    -> GhcOptions
componentGhcOptions = Internal.componentGhcOptions

-- -----------------------------------------------------------------------------
-- Installing

-- |Install executables for GHC.
installExe :: Verbosity
           -> LocalBuildInfo
           -> InstallDirs FilePath -- ^Where to copy the files to
           -> FilePath  -- ^Build location
           -> (FilePath, FilePath)  -- ^Executable (prefix,suffix)
           -> PackageDescription
           -> Executable
           -> IO ()
installExe verbosity lbi installDirs buildPref
  (progprefix, progsuffix) _pkg exe = do
  let binDir = bindir installDirs
  createDirectoryIfMissingVerbose verbosity True binDir
  let exeFileName = exeName exe <.> exeExtension
      fixedExeBaseName = progprefix ++ exeName exe ++ progsuffix
      installBinary dest = do
          installExecutableFile verbosity
            (buildPref </> exeName exe </> exeFileName)
            (dest <.> exeExtension)
          when (stripExes lbi) $
            Strip.stripExe verbosity (hostPlatform lbi) (withPrograms lbi)
                           (dest <.> exeExtension)
  installBinary (binDir </> fixedExeBaseName)

-- |Install for ghc, .hi, .a and, if --with-ghci given, .o
installLib    :: Verbosity
              -> LocalBuildInfo
              -> FilePath  -- ^install location
              -> FilePath  -- ^install location for dynamic libraries
              -> FilePath  -- ^Build location
              -> PackageDescription
              -> Library
              -> ComponentLocalBuildInfo
              -> IO ()
installLib verbosity lbi targetDir dynlibTargetDir builtDir _pkg lib clbi = do
  -- copy .hi files over:
  whenVanilla $ copyModuleFiles "hi"
  whenProf    $ copyModuleFiles "p_hi"
  whenShared  $ copyModuleFiles "dyn_hi"

  -- copy the built library files over:
  whenVanilla $ mapM_ (installOrdinary builtDir targetDir)       vanillaLibNames
  whenProf    $ mapM_ (installOrdinary builtDir targetDir)       profileLibNames
  whenGHCi    $ mapM_ (installOrdinary builtDir targetDir)       ghciLibNames
  whenShared  $ mapM_ (installShared   builtDir dynlibTargetDir) sharedLibNames

  where
    install isShared srcDir dstDir name = do
      let src = srcDir </> name
          dst = dstDir </> name
      createDirectoryIfMissingVerbose verbosity True dstDir
      if isShared
        then do when (stripLibs lbi) $ Strip.stripLib verbosity
                                       (hostPlatform lbi) (withPrograms lbi) src
                installExecutableFile verbosity src dst
        else installOrdinaryFile   verbosity src dst

    installOrdinary = install False
    installShared   = install True

    copyModuleFiles ext =
      findModuleFiles [builtDir] [ext] (libModules lib)
      >>= installOrdinaryFiles verbosity targetDir

    cid = compilerId (compiler lbi)
    libNames = componentLibraries clbi
    vanillaLibNames = map mkLibName              libNames
    profileLibNames = map mkProfLibName          libNames
    ghciLibNames    = map Internal.mkGHCiLibName libNames
    sharedLibNames  = map (mkSharedLibName cid)  libNames

    hasLib    = not $ null (libModules lib)
                   && null (cSources (libBuildInfo lib))
    whenVanilla = when (hasLib && withVanillaLib lbi)
    whenProf    = when (hasLib && withProfLib    lbi)
    whenGHCi    = when (hasLib && withGHCiLib    lbi)
    whenShared  = when (hasLib && withSharedLib  lbi)

-- -----------------------------------------------------------------------------
-- Registering

-- | Create an empty package DB at the specified location.
initPackageDB :: Verbosity -> ProgramConfiguration -> FilePath -> IO ()
initPackageDB verbosity conf dbPath =
  HcPkg.init verbosity (ghcVersionImplProps ver) ghcPkgProg dbPath
    where
      Just ghcPkgProg = lookupProgram ghcPkgProgram conf
      Just ver        = programVersion ghcPkgProg

-- | Run 'ghc-pkg' using a given package DB stack, directly forwarding the
-- provided command-line arguments to it.
invokeHcPkg :: Verbosity -> ProgramConfiguration -> PackageDBStack -> [String]
            -> IO ()
invokeHcPkg verbosity conf dbStack extraArgs =
    HcPkg.invoke verbosity (ghcVersionImplProps ver) ghcPkgProg
      dbStack extraArgs
  where
    Just ghcPkgProg = lookupProgram ghcPkgProgram conf
    Just ver        = programVersion ghcPkgProg

registerPackage
  :: Verbosity
  -> InstalledPackageInfo
  -> PackageDescription
  -> LocalBuildInfo
  -> Bool
  -> PackageDBStack
  -> IO ()
registerPackage verbosity installedPkgInfo _pkg lbi _inplace packageDbs = do
  let Just ghcPkg = lookupProgram ghcPkgProgram (withPrograms lbi)
      Just ver    = programVersion ghcPkg
  HcPkg.reregister verbosity (ghcVersionImplProps ver) ghcPkg
    packageDbs (Right installedPkgInfo)

-- -----------------------------------------------------------------------------
-- Utils

ghcDynamic :: Compiler -> Bool
ghcDynamic = Internal.ghcLookupProperty "GHC Dynamic"

ghcSupportsDynamicToo :: Compiler -> Bool
ghcSupportsDynamicToo = Internal.ghcLookupProperty "Support dynamic-too"

