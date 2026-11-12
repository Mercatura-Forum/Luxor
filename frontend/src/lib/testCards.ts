import type { TestScenario } from '../api/types'

/**
 * THE TEST GATEWAY'S CARDS. A card number never leaves the page: the published test numbers are
 * recognised here and mapped to a scenario, and only the scenario goes to the gateway, which answers
 * with an authorisation reference. Any other number is refused before anything is sent. The guest's
 * payment page and the desk's "take payment" read the same table.
 */
export const TEST_CARDS: Record<string, TestScenario> = {
  '4242424242424242': 'approve',
  '4000000000000002': 'decline',
  '4000000000009995': 'insufficient',
  '4000000000005126': 'refundDeclined',
  // approves the guest's payment and keeps the card, then declines any later charge to it (a no-show)
  '4000000000000341': 'mitDeclined',
}

/** A card number as it is typed, in groups of four. */
export function groups(v: string) { return v.replace(/\D/g, '').slice(0, 16).replace(/(\d{4})(?=\d)/g, '$1 ') }

/** The scenario a typed number names, or null for a number that is not a test card. */
export function scenarioOf(card: string): TestScenario | null { return TEST_CARDS[card.replace(/\D/g, '')] ?? null }
