import SwiftUI

struct SideBarView: View {
    @Binding var isShowing: Bool
    
    var body: some View {
        ZStack {
            if isShowing {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture {
                        isShowing = false
                    }
                
                HStack {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .center, spacing: 15) {
                            Text("左侧菜单")
                                .font(.title)
                                .padding(.top, 50)
                        }
                        
                        VStack(alignment: .leading, spacing: 15) {
                            MenuButton(title: "Home", icon: "house.fill")
                            MenuButton(title: "Settings", icon: "gear")
                            MenuButton(title: "About", icon: "info.circle")
                        }
                        .padding(.top, 30)
                        
                        Spacer()
                    }
                    .padding()
                    .frame(width: 250)
                    .background(Color(.systemGray6))
                    
                    Spacer()
                }
                .transition(.move(edge: .leading))
            }
        }
        .animation(.easeInOut, value: isShowing)
    }
}

struct MenuButton: View {
    let title: String
    let icon: String
    
    var body: some View {
        Button(action: {
            // Add action here
        }) {
            HStack {
                Image(systemName: icon)
                    .frame(width: 24, height: 24)
                Text(title)
                Spacer()
            }
            .foregroundColor(.primary)
        }
    }
}

#Preview {
    SideBarView(isShowing: .constant(true))
}
