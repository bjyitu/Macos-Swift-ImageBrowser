#!/bin/bash

# ImageBrowser图片浏览器应用构建脚本（简化版）
# 专注于快速构建ImageBrowser.app应用程序

set -e  # 遇到错误立即退出

# 配置参数
APP_NAME="ImageBrowser"
BUILD_DIR=".build"
RELEASE_DIR="release"
APP_BUNDLE="$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"

# 应用图标
# Info.plist 里声明的是 CFBundleIconFile = AppIcon（不带扩展名，macOS 会自动补 .icns），
# 因此 Resources 里必须存在 AppIcon.icns —— 直接放 PNG 不会被 Finder / Dock 采纳。
# 这里从下面的 1024×1024 源图生成 macOS 要求的多分辨率 icns。
ICON_SOURCE="Assets/ImageBrowser.png"
ICON_NAME="AppIcon"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查依赖
check_dependencies() {
    log_info "检查系统依赖..."
    
    if ! command -v swift &> /dev/null; then
        log_error "Swift未安装，请先安装Xcode命令行工具"
        exit 1
    fi
    
    if ! xcode-select -p &> /dev/null; then
        log_error "Xcode命令行工具未安装"
        log_info "运行命令: xcode-select --install"
        exit 1
    fi
    
    log_success "所有依赖检查通过"
}

# 清理构建目录
clean_build() {
    log_info "清理构建目录..."
    
    if [ -d "$BUILD_DIR" ]; then
        rm -rf "$BUILD_DIR"
        log_success "构建目录已清理"
    fi
    
    if [ -d "$RELEASE_DIR" ]; then
        rm -rf "$RELEASE_DIR"
        log_success "发布目录已清理"
    fi
}

# 构建应用程序
build_app() {
    log_info "开始构建应用程序..."
    clean_build
    # 创建发布目录
    mkdir -p "$RELEASE_DIR"
    
    # 构建通用二进制（Universal Binary）
    log_info "编译通用二进制版本（x86_64 + arm64）..."
    
    # 构建x86_64架构
    log_info "构建x86_64架构..."
    swift build -c release --arch x86_64
    
    if [ $? -ne 0 ]; then
        log_error "x86_64架构构建失败"
        exit 1
    fi
    
    # 构建arm64架构
    log_info "构建arm64架构..."
    swift build -c release --arch arm64
    
    if [ $? -ne 0 ]; then
        log_error "arm64架构构建失败"
        exit 1
    fi
    
    # 合并两个架构为通用二进制
    log_info "合并架构为通用二进制..."
    lipo -create \
        "$BUILD_DIR/x86_64-apple-macosx/release/ImageBrowser" \
        "$BUILD_DIR/arm64-apple-macosx/release/ImageBrowser" \
        -output "$BUILD_DIR/release/ImageBrowser"
    
    if [ $? -ne 0 ]; then
        log_error "架构合并失败"
        exit 1
    fi
    
    log_success "应用程序构建成功（通用二进制）"
}

# 生成应用图标：从 ICON_SOURCE（PNG）生成多分辨率 .icns
#
# 为什么不能直接拷 PNG：macOS 只认 .icns；而且必须是**多分辨率**的，
# 否则在 Dock / 访达小图标尺寸下会模糊或显示异常。
# 所以这里用 sips 从源图生成全部档位，再用 iconutil 打包。
# 失败不中断构建（图标缺失只会退回系统默认图标）。
build_app_icon() {
    local src_png="$1"
    local out_icns="$2"
    
    if [ ! -f "$src_png" ]; then
        log_warning "未找到图标源文件 $src_png，跳过图标（应用将使用系统默认图标）"
        return 0
    fi
    
    if ! command -v iconutil &> /dev/null || ! command -v sips &> /dev/null; then
        log_warning "缺少 sips / iconutil，跳过图标"
        return 0
    fi
    
    log_info "生成应用图标..."
    
    local tmp_dir iconset
    tmp_dir="$(mktemp -d)"
    iconset="$tmp_dir/$ICON_NAME.iconset"
    mkdir -p "$iconset"
    
    # macOS 要求的全部档位：1x 与 @2x 成对，源图 1024×1024
    local spec size name failed=false
    for spec in \
        "16 icon_16x16" "32 icon_16x16@2x" \
        "32 icon_32x32" "64 icon_32x32@2x" \
        "128 icon_128x128" "256 icon_128x128@2x" \
        "256 icon_256x256" "512 icon_256x256@2x" \
        "512 icon_512x512" "1024 icon_512x512@2x"
    do
        size="${spec%% *}"
        name="${spec##* }"
        # 用 || 兜住，避免 set -e 因单档失败而中断整个构建
        sips -z "$size" "$size" "$src_png" --out "$iconset/$name.png" > /dev/null || failed=true
    done
    
    if [ "$failed" = false ] && iconutil -c icns "$iconset" -o "$out_icns" 2>/dev/null; then
        log_success "应用图标已生成: $ICON_NAME.icns（$(basename "$src_png") → 10 档尺寸）"
    else
        log_warning "图标生成失败，应用将使用系统默认图标"
    fi
    
    rm -rf "$tmp_dir"
}

# 创建应用包
create_app_bundle() {
    log_info "创建应用包结构..."
    
    # 创建应用包目录结构
    mkdir -p "$RELEASE_DIR/$APP_MACOS"
    mkdir -p "$RELEASE_DIR/$APP_RESOURCES"
    
    # 生成并放入应用图标（Resources/AppIcon.icns，与 Info.plist 的 CFBundleIconFile 对应）
    build_app_icon "$ICON_SOURCE" "$RELEASE_DIR/$APP_RESOURCES/$ICON_NAME.icns"
    
    # 复制可执行文件
    cp "$BUILD_DIR/release/ImageBrowser" "$RELEASE_DIR/$APP_MACOS/"
    
    # 复制Info.plist文件
     if [ -f "Info.plist" ]; then
         cp "Info.plist" "$RELEASE_DIR/$APP_CONTENTS/"
         log_success "Info.plist文件已复制"
     else
         log_error "Info.plist文件不存在，请确保项目根目录有Info.plist文件"
         exit 1
     fi
    
    # 创建PkgInfo文件
    echo "APPL????" > "$RELEASE_DIR/$APP_CONTENTS/PkgInfo"
    
    log_success "应用包结构创建完成"
}

# 快速构建（不清理）
quick_build() {
    log_info "快速构建模式..."
    
    # 直接构建通用二进制
    log_info "构建通用二进制..."
    swift build -c release --arch x86_64
    
    if [ $? -ne 0 ]; then
        log_error "快速构建失败，尝试完整构建"
        clean_build
        build_app
        create_app_bundle
    else
        # 快速模式下只构建当前架构，不构建通用二进制
        log_info "快速模式：仅构建当前架构"
        
        # 更新应用包
        if [ -d "$RELEASE_DIR/$APP_BUNDLE" ]; then
            cp "$BUILD_DIR/release/ImageBrowser" "$RELEASE_DIR/$APP_MACOS/"
            log_success "应用程序已更新（当前架构）"
        else
            create_app_bundle
        fi
    fi
}

# 显示构建结果
show_build_result() {
    log_success "构建流程完成！"
    echo ""
    echo "📦 生成的文件:"
    echo "   可执行文件: $BUILD_DIR/release/ImageBrowser"
    echo "   应用包: $RELEASE_DIR/$APP_BUNDLE"
    echo "   应用图标: $RELEASE_DIR/$APP_RESOURCES/$ICON_NAME.icns"
    echo ""
    echo "💡 使用方法:"
    echo "   直接运行: open $RELEASE_DIR/$APP_BUNDLE"
    echo "   复制到应用程序: cp -R $RELEASE_DIR/$APP_BUNDLE /Applications/"
    echo "   快速更新: ./build_ImageBrowser_app.sh -q"
}

# 显示帮助信息
show_help() {
    echo "ImageBrowser应用构建脚本（简化版）"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -c, --clean     清理并重新构建"
    echo "  -q, --quick     快速构建（不清理）"
    echo "  -h, --help      显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  $0             标准构建"
    echo "  $0 -q          快速更新应用"
    echo "  $0 -c          清理后重新构建"
}

# 主函数
main() {
    local clean=false
    local quick=false
    
    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--clean)
                clean=true
                shift
                ;;
            -q|--quick)
                quick=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "未知选项: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    # 检查依赖
    check_dependencies
    
    # 处理不同模式
    if [ "$quick" = true ]; then
        # 快速构建
        quick_build
    elif [ "$clean" = true ]; then
        # 清理构建
        clean_build
        build_app
        create_app_bundle
    else
        # 标准构建
        build_app
        create_app_bundle
    fi
    
    # 显示构建结果
    show_build_result
}

# 运行主函数
main "$@"