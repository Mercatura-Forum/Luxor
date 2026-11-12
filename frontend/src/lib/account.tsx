/**
 * The guest's account: a Memphis passkey session, on a hotel whose contract uses passkeys. The page
 * holds only the token scoped to this site (the SDK's session module); the contract verifies it with
 * Memphis. A session is opened once with an update, so the account's own views (a query cannot await
 * Memphis) can read it from the contract's cache.
 */
import { createContext, useContext, useEffect, useState, type ReactNode } from 'react'
import { useMemphisConnect } from '@thebes/sdk'
import { useApp } from '../app'

interface Account {
  /** Passkeys are how this hotel knows its guests. */
  available: boolean
  signedIn: boolean
  name: string
  token: string
  ready: boolean
  signIn(): Promise<void>
  signOut(): void
  busy: boolean
}

const Ctx = createContext<Account | null>(null)

export function AccountProvider({ children }: { children: ReactNode }) {
  const { api } = useApp()
  const auth = useMemphisConnect('Luxor')
  const [available, setAvailable] = useState(false)
  const [ready, setReady] = useState(false)

  useEffect(() => { let live = true; api.identity().then((m) => live && setAvailable(m === 'memphis')).catch(() => live && setAvailable(false)); return () => { live = false } }, [api])
  useEffect(() => {
    setReady(false)
    if (!available || !auth.token) return
    let live = true
    api.openSession(auth.token).then(() => live && setReady(true)).catch(() => live && setReady(false))
    return () => { live = false }
  }, [api, available, auth.token])

  const value: Account = {
    available, signedIn: available && auth.signedIn, name: auth.displayName, token: auth.token ?? '', ready,
    signIn: () => auth.signIn({ mode: 'auto' }), signOut: auth.signOut, busy: auth.busy,
  }
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>
}

export function useAccount(): Account {
  const c = useContext(Ctx)
  if (!c) throw new Error('useAccount outside AccountProvider')
  return c
}
