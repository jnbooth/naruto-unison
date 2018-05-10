{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE ViewPatterns          #-}

-- | Yesod-provided implementation of 'Foundation'.
module Application
    ( getApplicationDev
    , appMain
    , develMain
    , makeFoundation
    , makeLogWare
    -- * for DevelMain
    , getApplicationRepl
    , shutdownApp
    -- * for GHCI
    , handler
    , db
    ) where

import Preludesque

import qualified STMContainers.Map   as M

import Control.Concurrent.STM.TChan         (newTChanIO)
import Control.Monad.Logger                 (liftLoc, runLoggingT)
import Database.Persist.Postgresql          (createPostgresqlPool, pgConnStr,
                                             pgPoolSize, runSqlPool)
import Language.Haskell.TH.Syntax           (qLocation)
import Network.Wai (Middleware)
import Network.Wai.Handler.Warp             (Settings, defaultSettings,
                                             defaultShouldDisplayException,
                                             runSettings, setHost,
                                             setOnException, setPort, getPort)
import Network.Wai.Middleware.RequestLogger (Destination (Logger),
                                             IPAddrSource (..),
                                             OutputFormat (..), destination,
                                             mkRequestLogger, outputFormat)
import System.Log.FastLogger                (defaultBufSize, newStdoutLoggerSet,
                                             toLogStr)

import Core.Import
import Handler.Embed
import Handler.PlayPage
import Handler.Play
import Handler.Test

mkYesodDispatch "App" resourcesApp

makeFoundation ∷ AppSettings → IO App
makeFoundation appSettings = do
    appHttpManager ← newManager
    appLogger  ← newStdoutLoggerSet defaultBufSize ≫= makeYesodLogger
    appStatic  ←
        (if appMutableStatic appSettings then staticDevel else static)
        (appStaticDir appSettings)
    appQueue    ← newTChanIO
    appPractice ← M.newIO

    let mkFoundation appConnPool = App {..}
        tempFoundation = mkFoundation $ error "connPool forced in tempFoundation"
        logFunc = messageLoggerSource tempFoundation appLogger

    pool ← flip runLoggingT logFunc $ createPostgresqlPool
        (pgConnStr  $ appDatabaseConf appSettings)
        (pgPoolSize $ appDatabaseConf appSettings)

    runLoggingT (runSqlPool (runMigration migrateAll) pool) logFunc

    return $ mkFoundation pool

makeApplication ∷ App → IO Application
makeApplication foundation = do
    logWare ← makeLogWare foundation
    appPlain ← toWaiAppPlain foundation
    return $ logWare $ defaultMiddlewaresNoLogging appPlain

makeLogWare ∷ App → IO Middleware
makeLogWare foundation =
    mkRequestLogger def
        { outputFormat =
            if appDetailedRequestLogging $ appSettings foundation
                then Detailed True
                else Apache
                        (if appIpFromHeader $ appSettings foundation
                            then FromFallback
                            else FromSocket)
        , destination = Logger $ loggerSet $ appLogger foundation
        }

warpSettings ∷ App → Settings
warpSettings foundation =
      setPort (appPort $ appSettings foundation)
    $ setHost (appHost $ appSettings foundation)
    $ setOnException (\_req e →
        when (defaultShouldDisplayException e) $ messageLoggerSource
            foundation
            (appLogger foundation)
            $(qLocation ≫= liftLoc)
            "yesod"
            LevelError
            (toLogStr $ "Exception from Warp: " ⧺ show e))
      defaultSettings

getApplicationDev ∷ IO (Settings, Application)
getApplicationDev = do
    settings ← loadYamlSettings [configSettingsYml] [] useEnv
    foundation ← makeFoundation settings
    wsettings ← getDevSettings $ warpSettings foundation
    app ← makeApplication foundation
    return (wsettings, app)

getAppSettings ∷ IO AppSettings
getAppSettings = loadYamlSettings [configSettingsYml] [] useEnv

develMain ∷ IO ()
develMain = develMainHelper getApplicationDev

appMain ∷ IO ()
appMain = do
    settings ← loadYamlSettingsArgs
        [configSettingsYmlValue]
        useEnv
    foundation ← makeFoundation settings
    app ← makeApplication foundation
    runSettings (warpSettings foundation) app


--------------------------------------------------------------
-- Functions for DevelMain.hs (a way to run the app from GHCi)
--------------------------------------------------------------
getApplicationRepl ∷ IO (Int, App, Application)
getApplicationRepl = do
    settings ← getAppSettings
    foundation ← makeFoundation settings
    wsettings ← getDevSettings $ warpSettings foundation
    app1 ← makeApplication foundation
    return (getPort wsettings, foundation, app1)

shutdownApp ∷ App → IO ()
shutdownApp _ = return ()


---------------------------------------------
-- Functions for use in development with GHCi
---------------------------------------------

handler ∷ Handler a → IO a
handler h = getAppSettings ≫= makeFoundation ≫= flip unsafeHandler h

db ∷ ReaderT SqlBackend (HandlerFor App) a → IO a
db = handler ∘ runDB
