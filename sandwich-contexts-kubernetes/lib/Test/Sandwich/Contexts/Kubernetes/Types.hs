{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Test.Sandwich.Contexts.Kubernetes.Types where

import Control.Monad.IO.Unlift
import Control.Monad.Logger
import Kubernetes.OpenAPI.Core as Kubernetes
import Network.HTTP.Client
import Relude
import Test.Sandwich
import Test.Sandwich.Contexts.Files
import Test.Sandwich.Contexts.Nix
import qualified Text.Show


instance Show Manager where
  show _ = "<HTTP manager>"

-- * Kubernetes cluster

data KubernetesClusterType =
  KubernetesClusterKind { kindBinary :: FilePath
                        , kindClusterName :: Text
                        , kindClusterDriver :: Text
                        , kindClusterEnvironment :: Maybe [(String, String)]
                        }
  | KubernetesClusterMinikube { minikubeBinary :: FilePath
                              , minikubeProfileName :: Text
                              , minikubeFlags :: [Text]
                              }
  deriving (Show, Eq)

data KubernetesClusterContext = KubernetesClusterContext {
  kubernetesClusterName :: Text
  , kubernetesClusterKubeConfigPath :: FilePath
  , kubernetesClusterNumNodes :: Int
  , kubernetesClusterClientConfig :: (Manager, Kubernetes.KubernetesClientConfig)
  , kubernetesClusterType :: KubernetesClusterType
  } deriving (Show)

kubernetesCluster :: Label "kubernetesCluster" KubernetesClusterContext
kubernetesCluster = Label
type HasKubernetesClusterContext context = HasLabel context "kubernetesCluster" KubernetesClusterContext

-- * Context

type KubernetesBasic m context = (
  MonadLoggerIO m
  , MonadUnliftIO m
  , HasBaseContextMonad context m
  )

type KubectlBasic m context = (
  KubernetesBasic m context
  , HasFile context "kubectl"
  , HasKubernetesClusterContext context
  )

type KubernetesClusterBasic m context = (
  KubectlBasic m context
  , HasKubernetesClusterContext context
  )

type NixContextBasic m context = (
  MonadLoggerIO m
  , MonadUnliftIO m
  , HasBaseContextMonad context m
  , HasNixContext context
  )

-- * Kubernetes cluster images

kubernetesClusterImages :: Label "kubernetesClusterImages" [Text]
kubernetesClusterImages = Label
type HasKubernetesClusterImagesContext context = HasLabel context "kubernetesClusterImages" [Text]

data ImagePullPolicy = Always | IfNotPresent | Never
  deriving (Show, Eq)

data ImageLoadSpec =
  -- | A @.tar@ or @.tar.gz@ file
  ImageLoadSpecTarball FilePath
  -- | An image pulled via Docker
  | ImageLoadSpecDocker { imageName :: Text
                        , pullPolicy :: ImagePullPolicy }
  -- | An image pulled via Podman
  | ImageLoadSpecPodman { imageName :: Text
                        , pullPolicy :: ImagePullPolicy }
  deriving (Show, Eq)
