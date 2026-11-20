#if os(iOS)
import SwiftUI

struct MailMessageDestination<Page: View>: ViewModifier {
    let session: AccountSession
    @Binding var opened: SignInBound<MailMessageRoute?>
    @ViewBuilder let page: (MailMessageRoute) -> Page

    func body(content: Content) -> some View {
        let signIn = session.currentSignIn
        content.navigationDestination(
            item: Binding(get: { opened.value }, set: { opened.set($0, for: signIn) }),
            destination: page
        )
    }
}
#endif
