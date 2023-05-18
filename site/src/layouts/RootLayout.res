@react.component
let make = (~children) => {
  let router = Next.Router.useRouter()

  switch router.route {
  | "/" => <MarketingSiteLayout> children </MarketingSiteLayout>
  | _ => <DashboardLayout> children </DashboardLayout>
  }
}
