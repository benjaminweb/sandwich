{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}

module Test.Sandwich.Contexts.Kubernetes.Cluster (
  KubernetesClusterContext (..)

  , Kind.introduceKindCluster

  , Minikube.introduceMinikubeClusterViaNix
  , Minikube.introduceMinikubeClusterViaEnvironment
  , Minikube.introduceMinikubeCluster'
  , Minikube.MinikubeClusterOptions(..)
  , Minikube.defaultMinikubeClusterOptions

  , waitForServiceEndpointsToExist

  , waitForPodsToExist
  , waitForPodsToBeReady

  , withForwardKubernetesService
  , withForwardKubernetesService'

  , kubernetesCluster
  , HasKubernetesClusterContext

  , module Test.Sandwich.Contexts.Kubernetes.KubectlLogs
  , module Test.Sandwich.Contexts.Kubernetes.KubectlPortForward

  -- * Util
  , Util.parseHostnameAndPort
  ) where

import Control.Monad.Catch
import Control.Monad.IO.Unlift
import Control.Monad.Logger
import Control.Monad.Reader
import Control.Monad.Trans.Control (MonadBaseControl)
import Network.URI
import Relude
import Test.Sandwich
import Test.Sandwich.Contexts.Kubernetes.KubectlLogs
import Test.Sandwich.Contexts.Kubernetes.KubectlPortForward
import Test.Sandwich.Contexts.Kubernetes.Types
import Test.Sandwich.Contexts.Kubernetes.Waits

import qualified Test.Sandwich.Contexts.Kubernetes.KindCluster as Kind
import qualified Test.Sandwich.Contexts.Kubernetes.KindCluster.ServiceForwardPortForward as Kind

import qualified Test.Sandwich.Contexts.Kubernetes.MinikubeCluster as Minikube
import qualified Test.Sandwich.Contexts.Kubernetes.MinikubeCluster.Forwards as Minikube

import qualified Test.Sandwich.Contexts.Kubernetes.Util as Util


withForwardKubernetesService :: (
  MonadLoggerIO m, MonadMask m, MonadUnliftIO m, MonadBaseControl IO m
  , MonadReader context m, HasBaseContext context, HasKubernetesClusterContext context
  ) => Text -> Text -> (URI -> m a) -> m a
withForwardKubernetesService namespace serviceName action = do
  kcc <- getContext kubernetesCluster
  withForwardKubernetesService' kcc namespace serviceName action

withForwardKubernetesService' :: (
  MonadLoggerIO m, MonadMask m, MonadUnliftIO m, MonadBaseControl IO m
  , MonadReader context m, HasBaseContext context
  ) => KubernetesClusterContext -> Text -> Text -> (URI -> m a) -> m a
withForwardKubernetesService' kcc@(KubernetesClusterContext {kubernetesClusterType=(KubernetesClusterMinikube {..})}) =
  Minikube.withForwardKubernetesService' kcc minikubeProfileName
withForwardKubernetesService' kcc@(KubernetesClusterContext {kubernetesClusterType=(KubernetesClusterKind {})}) =
  Kind.withForwardKubernetesService' kcc