{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -fno-warn-missing-signatures #-}
module Test.IO.Loom.Projector where

import           Control.Monad.Trans.Class (lift)

import           Loom.Projector

import qualified Data.Text.IO as T

import           Disorder.Core (ExpectedTestSpeed (..), disorderCheckEnvAll)
import           Disorder.Core.IO (testIO)
import           Disorder.Either (testEitherT)

import           P

import           System.Directory (createDirectoryIfMissing, doesFileExist)
import           System.FilePath ((</>))
import           System.IO (IO)
import           System.IO.Temp (withTempDirectory)

import           Test.QuickCheck (Gen)
import qualified Test.QuickCheck as QC

import           X.Control.Monad.Trans.Either (runEitherT)

prop_projector_success =
  QC.forAll genModuleName $ \name ->
  testIO . withProjector $ \dir -> do
    let
       dir1 = dir </> "dir1"
       dir2 = dir </> "dir2"
       f1 = dir1 <> "/test1.pjr"
       f2 = dir2 <> "/test2.pjr"
    lift $ createDirectoryIfMissing True dir1
    lift $ createDirectoryIfMissing True dir2
    lift $ writeFile f1 "\\foo : Foo ->\n<a>b</a>"
    lift $ writeFile f2 "\\bar : Bar\nfoo : Foo ->\n { test1 foo }"
    out <- compileProjector mempty [
        ProjectorInput name dir1 [f1]
      , ProjectorInput name dir2 [f2]
      ]
    f3 <- lift $ generateProjectorHaskell dir out
    lift . fmap QC.conjoin . mapM (doesFileExist . (</>) dir) $ f3

prop_projector_missing =
  QC.forAll genModuleName $ \name ->
  QC.once . testIO . withProjector $ \dir -> do
    m <- lift . runEitherT $ compileProjector mempty [ProjectorInput name dir ["missing.scss"]]
    pure $ isLeft m

prop_projector_fail =
  QC.forAll genModuleName $ \name ->
  QC.once . testIO . withProjector $ \dir -> do
    let
       f1 = dir <> "/test1.prj"
    lift $ writeFile f1 "\\x"
    m <- lift . runEitherT $ compileProjector mempty [ProjectorInput name dir [f1]]
    pure $ isLeft m

-------------

genModuleName :: Gen ModuleName
genModuleName =
  fmap moduleNameFromFile . QC.listOf1 . QC.choose $ ('a', 'z')

withProjector f =
  withTempDirectory "dist" "loom-projector" $ \dir ->
    testEitherT renderProjectorError $
      f dir

writeFile =
  T.writeFile

return []
tests :: IO Bool
tests = $disorderCheckEnvAll TestRunFewer