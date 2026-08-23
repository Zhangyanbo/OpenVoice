# dmgbuild 布局配置:经典「拖进应用程序」安装窗口
# 用法(由 scripts/build.sh 调用):
#   dmgbuild -s scripts/dmg_settings.py -D app=<path/to/OpenVoice.app> OpenVoice dist/OpenVoice.dmg
import os.path

app = defines.get("app", "build/Build/Products/Release/OpenVoice.app")  # noqa: F821
appname = os.path.basename(app)

# 内容:左边 app,右边指向 /Applications 的替身
files = [(app, appname)]
symlinks = {"Applications": "/Applications"}

# 窗口与图标布局
window_rect = ((200, 180), (540, 300))
icon_size = 100
text_size = 12
icon_locations = {
    appname: (140, 120),
    "Applications": (400, 120),
}
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

# 卷标图标用 app 自己的图标
_icns = os.path.join(app, "Contents/Resources/AppIcon.icns")
if os.path.exists(_icns):
    badge_icon = _icns

format = "UDZO"  # 压缩只读
