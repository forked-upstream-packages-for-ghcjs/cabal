-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.Simple.GHC.Internal
-- Copyright   :  Isaac Jones 2003-2007
--
-- Maintainer  :  cabal-devel@haskell.org
-- Portability :  portable
--
-- This module contains functions shared by GHC (Distribution.Simple.GHC)
-- and GHC-derived compilers.

{- Copyright (c) 2003-2005, Isaac Jones
All rights reserved.

Redistribution and use in source and binary forms, with or without
modiication, are permitted provided that the following conditions are
met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.

    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.

    * Neither the name of Isaac Jones nor the names of other
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. -}

module Distribution.Simple.GHC.Internal (
        configureToolchain,
        getLanguages,
        getExtensions,
        targetPlatform,
        getGhcInfo,
        componentCcGhcOptions,
        componentGhcOptions,
        mkGHCiLibName,
        filterGhciFlags,
        ghcLookupProperty,
        getHaskellObjects,
        mkGhcOptPackages
 ) where

import Distribution.Simple.GHC.Props ( ImplProps (..) )
import Distribution.Package
         ( InstalledPackageId, PackageId )
import Distribution.PackageDescription as PD
         ( BuildInfo(..)
         , Library(..), libModules
         , hcOptions
         , usedExtensions )
import Distribution.PackageDescription ( ModuleRenaming, lookupRenaming )
import Distribution.Compat.Exception ( catchExit, catchIO )
import Distribution.Simple.Compiler
         ( CompilerFlavor(..), Compiler(..), OptimisationLevel(..) )
import Distribution.Simple.Program.GHC
import Distribution.Simple.Setup
         ( toFlag )
import qualified Distribution.ModuleName as ModuleName
import Distribution.Simple.Program
         ( Program(..), ConfiguredProgram(..), ProgramConfiguration
         , ProgramLocation(..), ProgramSearchPath, ProgramSearchPathEntry(..)
         , rawSystemProgram, rawSystemProgramStdout, programPath
         , addKnownProgram, arProgram, ldProgram, gccProgram, stripProgram
         , getProgramOutput )
import Distribution.Simple.Program.Types ( suppressOverrideArgs )
import Distribution.Simple.LocalBuildInfo
         ( LocalBuildInfo(..), ComponentLocalBuildInfo(..)
         , LibraryName(..) )
import Distribution.Simple.Utils
import Distribution.Simple.BuildPaths
import Distribution.System ( buildOS, OS(..), Platform, platformFromTriple )
import Distribution.Text ( display, simpleParse )
import Distribution.Utils.NubList ( toNubListR )
import Distribution.Verbosity
import Language.Haskell.Extension
         ( Language(..), Extension(..), KnownExtension(..) )

import qualified Data.Map as M
import Data.Char                ( isSpace )
import Data.Maybe               ( fromMaybe, maybeToList )
import Data.Monoid              ( Monoid(..) )
import System.Directory         ( getDirectoryContents, getTemporaryDirectory )
import System.FilePath          ( (</>), (<.>), takeExtension, takeDirectory )
import System.IO                ( hClose, hPutStrLn )

targetPlatform :: [(String, String)] -> Maybe Platform
targetPlatform ghcInfo = platformFromTriple =<< lookup "Target platform" ghcInfo

-- | Adjust the way we find and configure gcc and ld
--
configureToolchain :: ImplProps
                   -> ConfiguredProgram
                   -> M.Map String String
                   -> ProgramConfiguration
                   -> ProgramConfiguration
configureToolchain props ghcProg ghcInfo =
    addKnownProgram gccProgram {
      programFindLocation = findProg gccProgram extraGccPath,
      programPostConf     = configureGcc
    }
  . addKnownProgram ldProgram {
      programFindLocation = findProg ldProgram extraLdPath,
      programPostConf     = configureLd
    }
  . addKnownProgram arProgram {
      programFindLocation = findProg arProgram extraArPath
    }
  . addKnownProgram stripProgram {
      programFindLocation = findProg stripProgram extraStripPath
    }
  where
    compilerDir = takeDirectory (programPath ghcProg)
    baseDir     = takeDirectory compilerDir
    mingwBinDir = baseDir </> "mingw" </> "bin"
    libDir      = baseDir </> "gcc-lib"
    includeDir  = baseDir </> "include" </> "mingw"
    isWindows   = case buildOS of Windows -> True; _ -> False
    binPrefix   = ""

    mkExtraPath :: Maybe FilePath -> FilePath -> [FilePath]
    mkExtraPath mbPath mingwPath | isWindows = mbDir ++ [mingwPath]
                                 | otherwise = mbDir
      where
        mbDir = maybeToList . fmap takeDirectory $ mbPath

    extraGccPath   = mkExtraPath mbGccLocation   windowsExtraGccDir
    extraLdPath    = mkExtraPath mbLdLocation    windowsExtraLdDir
    extraArPath    = mkExtraPath mbArLocation    windowsExtraArDir
    extraStripPath = mkExtraPath mbStripLocation windowsExtraStripDir

    -- on Windows finding and configuring ghc's gcc & binutils is a bit special
    (windowsExtraGccDir, windowsExtraLdDir,
     windowsExtraArDir, windowsExtraStripDir)
      | separateGccMingw props = (baseDir, libDir, libDir, libDir)
      | otherwise              = -- GHC >= 6.12
          let b = mingwBinDir </> binPrefix
          in  (b, b, b, b)

    findProg :: Program -> [FilePath]
             -> Verbosity -> ProgramSearchPath -> IO (Maybe FilePath)
    findProg prog extraPath v searchpath =
        programFindLocation prog v searchpath'
      where
        searchpath' = (map ProgramSearchPathDir extraPath) ++ searchpath

    -- Read tool locations from the 'ghc --info' output. Useful when
    -- cross-compiling.
    mbGccLocation   = M.lookup "C compiler command" ghcInfo
    mbLdLocation    = M.lookup "ld command" ghcInfo
    mbArLocation    = M.lookup "ar command" ghcInfo
    mbStripLocation = M.lookup "strip command" ghcInfo

    ccFlags        = getFlags "C compiler flags"
    gccLinkerFlags = getFlags "Gcc Linker flags"
    ldLinkerFlags  = getFlags "Ld Linker flags"

    getFlags key = case M.lookup key ghcInfo of
                   Nothing -> []
                   Just flags ->
                       case reads flags of
                       [(args, "")] -> args
                       _ -> [] -- XXX Should should be an error really

    configureGcc :: Verbosity -> ConfiguredProgram -> IO ConfiguredProgram
    configureGcc v gccProg = do
      gccProg' <- configureGcc' v gccProg
      return gccProg' {
        programDefaultArgs = programDefaultArgs gccProg'
                             ++ ccFlags ++ gccLinkerFlags
      }

    configureGcc' :: Verbosity -> ConfiguredProgram -> IO ConfiguredProgram
    configureGcc'
      | isWindows = \_ gccProg -> case programLocation gccProg of
          -- if it's found on system then it means we're using the result
          -- of programFindLocation above rather than a user-supplied path
          -- Pre GHC 6.12, that meant we should add these flags to tell
          -- ghc's gcc where it lives and thus where gcc can find its
          -- various files:
          FoundOnSystem {}
           | separateGccMingw props ->
               return gccProg { programDefaultArgs = ["-B" ++ libDir,
                                                      "-I" ++ includeDir] }
          _ -> return gccProg
      | otherwise = \_ gccProg -> return gccProg

    configureLd :: Verbosity -> ConfiguredProgram -> IO ConfiguredProgram
    configureLd v ldProg = do
      ldProg' <- configureLd' v ldProg
      return ldProg' {
        programDefaultArgs = programDefaultArgs ldProg' ++ ldLinkerFlags
      }

    -- we need to find out if ld supports the -x flag
    configureLd' :: Verbosity -> ConfiguredProgram -> IO ConfiguredProgram
    configureLd' verbosity ldProg = do
      tempDir <- getTemporaryDirectory
      ldx <- withTempFile tempDir ".c" $ \testcfile testchnd ->
             withTempFile tempDir ".o" $ \testofile testohnd -> do
               hPutStrLn testchnd "int foo() { return 0; }"
               hClose testchnd; hClose testohnd
               rawSystemProgram verbosity ghcProg ["-c", testcfile,
                                                   "-o", testofile]
               withTempFile tempDir ".o" $ \testofile' testohnd' ->
                 do
                   hClose testohnd'
                   _ <- rawSystemProgramStdout verbosity ldProg
                     ["-x", "-r", testofile, "-o", testofile']
                   return True
                 `catchIO`   (\_ -> return False)
                 `catchExit` (\_ -> return False)
      if ldx
        then return ldProg { programDefaultArgs = ["-x"] }
        else return ldProg

getLanguages :: Verbosity -> ImplProps -> ConfiguredProgram
             -> IO [(Language, String)]
getLanguages _ props _
  -- TODO: should be using --supported-languages rather than hard coding
  | supportsHaskell2010 props = return [(Haskell98,   "-XHaskell98")
                                       ,(Haskell2010, "-XHaskell2010")]
  | otherwise                 = return [(Haskell98,   "")]

getGhcInfo :: Verbosity -> ImplProps -> ConfiguredProgram
           -> IO [(String, String)]
getGhcInfo verbosity props ghcProg
  | flagInfoLanguages props = do
      xs <- getProgramOutput verbosity (suppressOverrideArgs ghcProg)
                 ["--info"]
      case reads xs of
        [(i, ss)]
          | all isSpace ss ->
              return i
        _ ->
          die "Can't parse --info output of GHC"
  | otherwise =
      return []

getExtensions :: Verbosity -> ImplProps -> ConfiguredProgram
              -> IO [(Extension, String)]
getExtensions verbosity props ghcProg
  | flagInfoLanguages props = do
    str <- getProgramOutput verbosity (suppressOverrideArgs ghcProg)
              ["--supported-languages"]
    let extStrs = if reportsNoExt props
                  then lines str
                  else -- Older GHCs only gave us either Foo or NoFoo,
                       -- so we have to work out the other one ourselves
                       [ extStr''
                       | extStr <- lines str
                       , let extStr' = case extStr of
                                       'N' : 'o' : xs -> xs
                                       _              -> "No" ++ extStr
                       , extStr'' <- [extStr, extStr']
                       ]
    let extensions0 = [ (ext, "-X" ++ display ext)
                      | Just ext <- map simpleParse extStrs ]
        extensions1 = if fakeRecordPuns props
                      then -- ghc-6.8 introduced RecordPuns however it
                           -- should have been NamedFieldPuns. We now
                           -- encourage packages to use NamedFieldPuns
                           -- so for compatibility we fake support for
                           -- it in ghc-6.8 by making it an alias for
                           -- the old RecordPuns extension.
                           (EnableExtension  NamedFieldPuns, "-XRecordPuns") :
                           (DisableExtension NamedFieldPuns, "-XNoRecordPuns") :
                           extensions0
                      else extensions0
        extensions2 = if alwaysNondecIndent props
                      then -- ghc-7.2 split NondecreasingIndentation off
                           -- into a proper extension. Before that it
                           -- was always on.
                           (EnableExtension  NondecreasingIndentation, "") :
                           (DisableExtension NondecreasingIndentation, "") :
                           extensions1
                      else extensions1
    return extensions2

  | otherwise = return oldLanguageExtensions

-- | For GHC 6.6.x and earlier, the mapping from supported extensions to flags
oldLanguageExtensions :: [(Extension, String)]
oldLanguageExtensions =
    let doFlag (f, (enable, disable)) = [(EnableExtension  f, enable),
                                         (DisableExtension f, disable)]
        fglasgowExts = ("-fglasgow-exts",
                        "") -- This is wrong, but we don't want to turn
                            -- all the extensions off when asked to just
                            -- turn one off
        fFlag flag = ("-f" ++ flag, "-fno-" ++ flag)
    in concatMap doFlag
    [(OverlappingInstances       , fFlag "allow-overlapping-instances")
    ,(TypeSynonymInstances       , fglasgowExts)
    ,(TemplateHaskell            , fFlag "th")
    ,(ForeignFunctionInterface   , fFlag "ffi")
    ,(MonomorphismRestriction    , fFlag "monomorphism-restriction")
    ,(MonoPatBinds               , fFlag "mono-pat-binds")
    ,(UndecidableInstances       , fFlag "allow-undecidable-instances")
    ,(IncoherentInstances        , fFlag "allow-incoherent-instances")
    ,(Arrows                     , fFlag "arrows")
    ,(Generics                   , fFlag "generics")
    ,(ImplicitPrelude            , fFlag "implicit-prelude")
    ,(ImplicitParams             , fFlag "implicit-params")
    ,(CPP                        , ("-cpp", ""{- Wrong -}))
    ,(BangPatterns               , fFlag "bang-patterns")
    ,(KindSignatures             , fglasgowExts)
    ,(RecursiveDo                , fglasgowExts)
    ,(ParallelListComp           , fglasgowExts)
    ,(MultiParamTypeClasses      , fglasgowExts)
    ,(FunctionalDependencies     , fglasgowExts)
    ,(Rank2Types                 , fglasgowExts)
    ,(RankNTypes                 , fglasgowExts)
    ,(PolymorphicComponents      , fglasgowExts)
    ,(ExistentialQuantification  , fglasgowExts)
    ,(ScopedTypeVariables        , fFlag "scoped-type-variables")
    ,(FlexibleContexts           , fglasgowExts)
    ,(FlexibleInstances          , fglasgowExts)
    ,(EmptyDataDecls             , fglasgowExts)
    ,(PatternGuards              , fglasgowExts)
    ,(GeneralizedNewtypeDeriving , fglasgowExts)
    ,(MagicHash                  , fglasgowExts)
    ,(UnicodeSyntax              , fglasgowExts)
    ,(PatternSignatures          , fglasgowExts)
    ,(UnliftedFFITypes           , fglasgowExts)
    ,(LiberalTypeSynonyms        , fglasgowExts)
    ,(TypeOperators              , fglasgowExts)
    ,(GADTs                      , fglasgowExts)
    ,(RelaxedPolyRec             , fglasgowExts)
    ,(ExtendedDefaultRules       , fFlag "extended-default-rules")
    ,(UnboxedTuples              , fglasgowExts)
    ,(DeriveDataTypeable         , fglasgowExts)
    ,(ConstrainedClassMethods    , fglasgowExts)
    ]

componentCcGhcOptions :: Verbosity -> ImplProps -> LocalBuildInfo
                      -> BuildInfo -> ComponentLocalBuildInfo
                      -> FilePath -> FilePath
                      -> GhcOptions
componentCcGhcOptions verbosity props lbi bi clbi pref filename =
    mempty {
      ghcOptVerbosity      = toFlag verbosity,
      ghcOptMode           = toFlag GhcModeCompile,
      ghcOptInputFiles     = toNubListR [filename],

      ghcOptCppIncludePath = toNubListR $ [autogenModulesDir lbi, odir]
                                          ++ PD.includeDirs bi,
      ghcOptPackageDBs     = withPackageDB lbi,
      ghcOptPackages       = toNubListR $ mkGhcOptPackages clbi,
      ghcOptCcOptions      = toNubListR $
                             (case withOptimization lbi of
                                  NoOptimisation -> []
                                  _              -> ["-O2"]) ++
                                  PD.ccOptions bi,
      ghcOptObjDir         = toFlag odir
    }
  where
    odir | hasCcOdirBug props  = pref </> takeDirectory filename
         | otherwise           = pref
         -- ghc 6.4.0 had a bug in -odir handling for C compilations.

componentGhcOptions :: Verbosity -> LocalBuildInfo
                    -> BuildInfo -> ComponentLocalBuildInfo -> FilePath
                    -> GhcOptions
componentGhcOptions verbosity lbi bi clbi odir =
    mempty {
      ghcOptVerbosity       = toFlag verbosity,
      ghcOptHideAllPackages = toFlag True,
      ghcOptCabal           = toFlag True,
      ghcOptPackageDBs      = withPackageDB lbi,
      ghcOptPackages        = toNubListR $ mkGhcOptPackages clbi,
      ghcOptSplitObjs       = toFlag (splitObjs lbi),
      ghcOptSourcePathClear = toFlag True,
      ghcOptSourcePath      = toNubListR $ [odir] ++ (hsSourceDirs bi)
                                           ++ [autogenModulesDir lbi],
      ghcOptCppIncludePath  = toNubListR $ [autogenModulesDir lbi, odir]
                                           ++ PD.includeDirs bi,
      ghcOptCppOptions      = toNubListR $ cppOptions bi,
      ghcOptCppIncludes     = toNubListR $
                              [autogenModulesDir lbi </> cppHeaderName],
      ghcOptFfiIncludes     = toNubListR $ PD.includes bi,
      ghcOptObjDir          = toFlag odir,
      ghcOptHiDir           = toFlag odir,
      ghcOptStubDir         = toFlag odir,
      ghcOptOutputDir       = toFlag odir,
      ghcOptOptimisation    = toGhcOptimisation (withOptimization lbi),
      ghcOptExtra           = toNubListR $ hcOptions GHC bi,
      ghcOptLanguage        = toFlag (fromMaybe Haskell98 (defaultLanguage bi)),
      -- Unsupported extensions have already been checked by configure
      ghcOptExtensions      = toNubListR $ usedExtensions bi,
      ghcOptExtensionMap    = M.fromList . compilerExtensions $ (compiler lbi)
    }
  where
    toGhcOptimisation NoOptimisation      = mempty --TODO perhaps override?
    toGhcOptimisation NormalOptimisation  = toFlag GhcNormalOptimisation
    toGhcOptimisation MaximumOptimisation = toFlag GhcMaximumOptimisation

-- | Strip out flags that are not supported in ghci
filterGhciFlags :: [String] -> [String]
filterGhciFlags = filter supported
  where
    supported ('-':'O':_) = False
    supported "-debug"    = False
    supported "-threaded" = False
    supported "-ticky"    = False
    supported "-eventlog" = False
    supported "-prof"     = False
    supported "-unreg"    = False
    supported _           = True

mkGHCiLibName :: LibraryName -> String
mkGHCiLibName (LibraryName lib) = lib <.> "o"

ghcLookupProperty :: String -> Compiler -> Bool
ghcLookupProperty prop comp =
  case M.lookup prop (compilerProperties comp) of
    Just "YES" -> True
    _          -> False

-- when using -split-objs, we need to search for object files in the
-- Module_split directory for each module.
getHaskellObjects :: ImplProps -> Library -> LocalBuildInfo
                  -> FilePath -> String -> Bool -> IO [FilePath]
getHaskellObjects props lib lbi pref wanted_obj_ext allow_split_objs
  | splitObjs lbi && allow_split_objs = do
        let splitSuffix = if noExtInSplitSuffix props
                          then "_split"
                          else "_" ++ wanted_obj_ext ++ "_split"
            dirs = [ pref </> (ModuleName.toFilePath x ++ splitSuffix)
                   | x <- libModules lib ]
        objss <- mapM getDirectoryContents dirs
        let objs = [ dir </> obj
                   | (objs',dir) <- zip objss dirs, obj <- objs',
                     let obj_ext = takeExtension obj,
                     '.':wanted_obj_ext == obj_ext ]
        return objs
  | otherwise  =
        return [ pref </> ModuleName.toFilePath x <.> wanted_obj_ext
               | x <- libModules lib ]

mkGhcOptPackages :: ComponentLocalBuildInfo
                 -> [(InstalledPackageId, PackageId, ModuleRenaming)]
mkGhcOptPackages clbi =
  map (\(i,p) -> (i,p,lookupRenaming p (componentPackageRenaming clbi)))
      (componentPackageDeps clbi)