import SwiftUI
import WebKit

struct TabBarView: View {
    @State private var selectedTab = 0
    @State private var isShowingDrawer = false
    @State private var isShowingMenu = false
    
    // Define your URLs here
    private let urls = [
        "https://www.baidu.com/",
        "https://juejin.cn/",
        "https://chat.deepseek.com/",
    ]
    
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Top Bar with Menu Button
                HStack {
                    Button(action: {
                        isShowingDrawer = true
                    }) {
                        Image(systemName: "line.3.horizontal")
                            .font(.title2)
                            .foregroundColor(.primary)
                    }
                    
                    Spacer()
                    
                    Text("PakePlus")
                    
                    Spacer()
                    
                    // 自定义菜单按钮
                    Button(action: {
                        isShowingMenu.toggle()
                    }) {
                        Image(systemName: "plus.circle")
                            .font(.title2)
                            .foregroundColor(.primary)
                    }
                }
                .background(Color(.systemBackground))
                .padding(.horizontal)
                .padding(.vertical, 6)
                
                // WebView for the selected URL
                WebView(
                    webUrl: URL(string: urls[selectedTab])!,
                    debug: false,
                    onLoadFinished: nil
                )
                    .edgesIgnoringSafeArea(.top)
                
                // Bottom Tab Bar
                HStack(spacing: 0) {
                    ForEach(0 ..< urls.count, id: \.self) { index in
                        Button(action: {
                            selectedTab = index
                        }) {
                            VStack {
                                Image(systemName: tabIcon(for: index))
                                    .font(.system(size: 20))
                                Text(tabTitle(for: index))
                                    .font(.caption)
                            }
                            .foregroundColor(selectedTab == index ? .blue : .gray)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                    }
                }
                .background(Color(.systemBackground))
                .overlay(
                    Rectangle()
                        .frame(height: 0.5)
                        .foregroundColor(Color(.systemGray4)),
                    alignment: .top
                )
            }
            
            // 自定义菜单
            if isShowingMenu {
                Image(systemName: "arrowtriangle.up.fill")
                    .resizable()
                    .frame(width: 30, height: 30)
                    .position(x: UIScreen.main.bounds.width - 30, y: 50)
                    .foregroundStyle(Color(.systemGray6))
                VStack(alignment: .trailing, spacing: 0) {
                    Button(action: {
                        // 复制网址动作
                        isShowingMenu = false
                    }) {
                        Text("复制网址")
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .frame(width: 100)
                    }
                    .background(Color(.systemGray6))
                    .cornerRadius(8, corners: [.topLeft, .topRight])
                    
                    Button(action: {
                        // 外部打开动作
                        isShowingMenu = false
                    }) {
                        Text("外部打开")
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .frame(width: 100)
                    }
                    .background(Color(.systemGray6))
                    
                    Button(action: {
                        // 重新加载动作
                        isShowingMenu = false
                    }) {
                        Text("重新加载")
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .frame(width: 100)
                    }
                    .background(Color(.systemGray6))
                    .cornerRadius(8, corners: [.bottomLeft, .bottomRight])
                }
                .position(x: UIScreen.main.bounds.width - 60, y: 100)
                .transition(.opacity)
                .background(Color.white.opacity(0.0001))
            }
            
            // Side Drawer
            SideBarView(isShowing: $isShowingDrawer)
        }
        .onTapGesture {
            if isShowingMenu {
                isShowingMenu = false
            }
        }
    }
    
    private func tabIcon(for index: Int) -> String {
        switch index {
        case 0:
            return "house.fill"
        case 1:
            return "star.fill"
        case 2:
            return "play.fill"
        default:
            return "circle.fill"
        }
    }
    
    private func tabTitle(for index: Int) -> String {
        switch index {
        case 0:
            return "首页"
        case 1:
            return "收藏"
        case 2:
            return "我的"
        default:
            return "Tab"
        }
    }
}

#Preview {
    TabBarView()
}

// Add RoundedCorner extension
struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect, byRoundingCorners: corners,
                                cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}

extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}
