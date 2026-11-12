import { StrictMode, lazy, Suspense } from 'react'
import { createRoot } from 'react-dom/client'
import { HashRouter, Navigate, Route, Routes } from 'react-router-dom'
import { Toaster } from './lib/toast'
import './index.css'
import { AppProvider } from './app'
import { AccountProvider } from './lib/account'
import { Layout } from './components/Layout'
import { Home } from './pages/Home'
// every search lands on the results, so they travel with the first script rather than a second fetch
import Results from './pages/Results'

// HashRouter: the gateway in front of the contract delivers the path only, so routes live after '#'.
const RoomPage = lazy(() => import('./pages/Room'))
const Details = lazy(() => import('./pages/Details'))
const Payment = lazy(() => import('./pages/Payment'))
const Confirmation = lazy(() => import('./pages/Confirmation'))
const Manage = lazy(() => import('./pages/Manage'))
const CardLink = lazy(() => import('./pages/CardLink'))
const NotFound = lazy(() => import('./pages/NotFound'))
const Rates = lazy(() => import('./console/Rates'))
const MyStays = lazy(() => import('./pages/MyStays'))
const Today = lazy(() => import('./console/Today'))
const BookingsPage = lazy(() => import('./console/Bookings'))
const NewBookingPage = lazy(() => import('./console/NewBooking'))
const AuditPage = lazy(() => import('./console/Audit'))
const ApprovalsPage = lazy(() => import('./console/Approvals'))
const HousekeepingPage = lazy(() => import('./console/Housekeeping'))
const RoomPlanPage = lazy(() => import('./console/RoomPlan'))
const ReportsPage = lazy(() => import('./console/Reports'))
const ExtrasPage = lazy(() => import('./console/Extras'))
const RateProductsPage = lazy(() => import('./console/RateProducts'))
const GroupsPage = lazy(() => import('./console/Groups'))
const InvoicePage = lazy(() => import('./console/Invoice'))
const CreditNotePage = lazy(() => import('./console/CreditNote'))
const StaffPage = lazy(() => import('./console/Staff'))
const SetupPage = lazy(() => import('./console/Setup'))
const ConsoleShell = lazy(() => import('./console/Shell'))
const GuestEmailPage = lazy(() => import('./console/GuestEmail'))

// A sign-in with Google or Microsoft returns from the mail relay to this page with the account's digest
// after '#' (the relay appends it; it is not a route). It is kept for the Guest email screen and the
// address bar is put back on that screen, so the digest never sits in the history.
if (/^#(mailCredential|mailError)=/.test(location.hash)) {
  try { sessionStorage.setItem('luxor:mailSignIn', location.hash.slice(1)) } catch { /* a private window: the screen asks to sign in again */ }
  history.replaceState(null, '', `${location.pathname}${location.search}#/console/email`)
}

// The home page's hero arrives painted from the HTML (index.html). The app draws its own elements in
// its place rather than adopting the painted ones: Preact would reuse the painted <img> and, updating
// it, have the browser record the photograph's paint again at that moment, later than people saw it.
// Clearing and drawing happen in one task, so no frame shows the page empty.
const root = document.getElementById('root')!
root.replaceChildren()
createRoot(root).render(
  <StrictMode>
    <AppProvider>
      <AccountProvider>
      <HashRouter>
        <Suspense fallback={<div className="min-h-[60vh]" />}>
          <Routes>
            <Route element={<Layout />}>
              <Route index element={<Home />} />
              <Route path="rooms" element={<Results />} />
              <Route path="rooms/:id" element={<RoomPage />} />
              <Route path="book/details" element={<Details />} />
              <Route path="book/payment" element={<Payment />} />
              <Route path="book/done" element={<Confirmation />} />
              <Route path="manage/:ref" element={<Manage />} />
              <Route path="card/:ref" element={<CardLink />} />
              <Route path="stays" element={<MyStays />} />
              <Route path="*" element={<NotFound />} />
            </Route>
            {/* the hotel team's console has its own frame, not the guest site's */}
            <Route path="console" element={<ConsoleShell />}>
              <Route index element={<Today />} />
              <Route path="today" element={<Navigate to="/console" replace />} />
              <Route path="rates" element={<Rates />} />
              <Route path="bookings" element={<BookingsPage />} />
              <Route path="book" element={<NewBookingPage />} />
              <Route path="audit" element={<AuditPage />} />
              <Route path="approvals" element={<ApprovalsPage />} />
              <Route path="room-plan" element={<RoomPlanPage />} />
              <Route path="reports" element={<ReportsPage />} />
              <Route path="housekeeping" element={<HousekeepingPage />} />
              <Route path="extras" element={<ExtrasPage />} />
              <Route path="products" element={<RateProductsPage />} />
              <Route path="groups" element={<GroupsPage />} />
              <Route path="invoice/:number" element={<InvoicePage />} />
              <Route path="credit-note/:number" element={<CreditNotePage />} />
              <Route path="staff" element={<StaffPage />} />
              <Route path="setup" element={<SetupPage />} />
              <Route path="email" element={<GuestEmailPage />} />
            </Route>
          </Routes>
        </Suspense>
      </HashRouter>
      </AccountProvider>
      <Toaster />
    </AppProvider>
  </StrictMode>,
)
