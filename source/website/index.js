import { Loc } from '../engine/core/localization.js';
import { AddDiv, AddDomElement } from '../engine/viewer/domutils.js';
import { Embed } from './embed.js';
import { Website } from './website.js';
import { SetEventHandler, HandleEvent } from './eventhandler.js';
import { PluginType, RegisterPlugin } from './pluginregistry.js';
import { ButtonDialog, ProgressDialog } from './dialog.js';
import { ShowMessageDialog } from './dialogs.js';
import { Native3dmStream } from './native3dmstream.js';

import * as Engine from '../engine/main.js';
export { Engine };

import './css/icons.css';
import './css/themes.css';
import './css/core.css';
import './css/controls.css';
import './css/dialogs.css';
import './css/treeview.css';
import './css/panelset.css';
import './css/navigator.css';
import './css/sidebar.css';
import './css/website.css';
import './css/embed.css';

export const UI = {
    ButtonDialog,
    ProgressDialog,
    ShowMessageDialog,
    HandleEvent,
    Loc
};

export function SetWebsiteEventHandler (eventHandler)
{
    SetEventHandler (eventHandler);
}

export function RegisterHeaderPlugin (plugin)
{
    RegisterPlugin (PluginType.Header, plugin);
}

export function RegisterToolbarPlugin (plugin)
{
    RegisterPlugin (PluginType.Toolbar, plugin);
}

export function StartWebsite ()
{
    window.addEventListener ('load', () => {
        if (window.self !== window.top) {
            let noEmbeddingDiv = AddDiv (document.body, 'noembed');
            AddDiv (noEmbeddingDiv, null, Loc ('Embedding Online 3D Viewer in an iframe is not supported.'));
            let link = AddDomElement (noEmbeddingDiv, 'a', null, Loc ('Open Online 3D Viewer'));
            link.target = '_blank';
            link.href = window.self.location;
            return;
        }

        document.getElementById ('intro_dragdrop_text').innerHTML = Loc ('Drag and drop 3D models here.');
        document.getElementById ('intro_formats_title').innerHTML = Loc ('Check an example file:');

        let website = new Website ({
            headerDiv : document.getElementById ('header'),
            headerButtonsDiv : document.getElementById ('header_buttons'),
            toolbarDiv : document.getElementById ('toolbar'),
            mainDiv : document.getElementById ('main'),
            introDiv : document.getElementById ('intro'),
            fileNameDiv : document.getElementById ('main_file_name'),
            leftContainerDiv : document.getElementById ('main_left_container'),
            navigatorDiv : document.getElementById ('main_navigator'),
            navigatorSplitterDiv : document.getElementById ('main_navigator_splitter'),
            rightContainerDiv : document.getElementById ('main_right_container'),
            sidebarDiv : document.getElementById ('main_sidebar'),
            sidebarSplitterDiv : document.getElementById ('main_sidebar_splitter'),
            viewerDiv : document.getElementById ('main_viewer'),
            fileInput : document.getElementById ('open_file')
        });
        if (window.O3DVNativeBridge === true) {
            const stream = new Native3dmStream (website);
            Engine.SetExternalLibraryBaseUrl (new URL ('assets/libs/', document.baseURI).href);
            window.O3DVOpenFiles = (urls) => {
                stream.Stop ();
                const settings = new Engine.ImportSettings ();
                settings.defaultLineColor = website.settings.defaultLineColor;
                settings.defaultColor = website.settings.defaultColor;
                website.LoadModelFromUrlList (urls, settings);
            };
            window.O3DVOpenStream = (url) => stream.Start (url);
            window.O3DVSetStreamLayers = (values) => stream.SetLayers (values);
            window.O3DVSetMemoryPolicy = (policy) => stream.pager.SetPolicy (policy);
            window.O3DVSetForeground = (value) => stream.pager.SetForeground (value);
            window.O3DVSetViewerPreferences = (values) => {
                const theme = values.background === 'dark' ? 2 : 1;
                if (website.settings.themeId !== theme) {
                    website.SwitchTheme (theme, true);
                }
                const color = theme === 2 ? [42, 43, 46] : [255, 255, 255];
                const current = website.settings.backgroundColor;
                if (current.r !== color[0] || current.g !== color[1] || current.b !== color[2] || current.a !== 255) {
                    website.settings.backgroundColor = new Engine.RGBAColor (...color, 255);
                    website.viewer.SetBackgroundColor (website.settings.backgroundColor);
                }
                const navigation = values.navigation === 'fixed' ? Engine.NavigationMode.FixedUpVector : Engine.NavigationMode.FreeOrbit;
                if (website.viewer.GetNavigationMode () !== navigation) {
                    website.cameraSettings.navigationMode = navigation;
                    website.viewer.SetNavigationMode (navigation);
                }
                const projection = values.projection === 'orthographic' ? Engine.ProjectionMode.Orthographic : Engine.ProjectionMode.Perspective;
                if (website.viewer.GetProjectionMode () !== projection) {
                    website.cameraSettings.projectionMode = projection;
                    website.viewer.SetProjectionMode (projection);
                }
            };
            window.O3DVStop = () => stream.Stop ();
            if (window.O3DVNativeDebug === true) {
                window.O3DVBenchmarkNavigation = () => stream.pager.BenchmarkNavigation ();
                window.O3DVGetViewerPreferences = () => ({
                    background : website.settings.backgroundColor.r,
                    navigation : website.viewer.GetNavigationMode (),
                    projection : website.viewer.GetProjectionMode ()
                });
            }
            window.O3DVGetThumbnail = () => {
                if (stream.active) {
                    return stream.pager.Thumbnail ();
                }
                const viewer = website.viewer;
                const camera = viewer.GetCamera ().Clone ();
                const size = viewer.GetImageSize ();
                try {
                    const ratio = window.devicePixelRatio || 1;
                    viewer.ResizeRenderer (360 / ratio, 360 / ratio);
                    viewer.FitSphereToWindow (viewer.GetBoundingSphere (() => true), false);
                    return viewer.GetImageAsDataUrl (360, 360, false);
                } finally {
                    viewer.ResizeRenderer (size.width, size.height);
                    viewer.SetCamera (camera);
                }
            };
            SetEventHandler ((eventName) => {
                const handler = window.webkit?.messageHandlers?.o3dv;
                if (handler) {
                    handler.postMessage ({ ...(eventName === 'model_loaded' ? website.lastImportDetails : {}),
                        type : eventName, name : website.model?.name || document.getElementById ('main_file_name').textContent });
                }
            });
        }
        website.Load ();
        if (window.O3DVNativeBridge === true) {
            document.body.classList.add ('o3dv-native-app');
            window.webkit?.messageHandlers?.o3dv?.postMessage ({ type : 'ready', navigationMode : website.viewer.GetNavigationMode () });
        }
    });
}

export function StartEmbed ()
{
    window.addEventListener ('load', () => {
        let embed = new Embed ({
            viewerDiv : document.getElementById ('embed_viewer'),
            websiteLinkDiv : document.getElementById ('website_link')
        });
        embed.Load ();
    });
}
