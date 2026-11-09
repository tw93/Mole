/**
 * Registers the Mole agent skill with DeepSeek Harness. The skill text is the
 * same copy the Claude Code and Codex plugins ship; this file only hands it to
 * the host's skill registry.
 */

import { readFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'

const SKILL_DIR = fileURLToPath(new URL('./skills/mole/', import.meta.url))
const SKILL_FILE = new URL('./skills/mole/SKILL.md', import.meta.url)
const PROVIDER = 'dsh-mole'
// BUNDLED_SKILL_RANK in @deepseek-ai/dsh-skill: a user's own `mole` skill wins.
const RANK = 600
const INVOCATION = { modelInvocable: true, userInvocable: true }
const RESOURCE_BASE = { kind: 'directory', path: SKILL_DIR }

function parseSkill(raw) {
  // A Git checkout on Windows may turn line endings into CRLF.
  const text = raw.replace(/\r\n/gu, '\n')
  const match = /^---\n([\s\S]*?)\n---\n/u.exec(text)
  if (match === null) throw new Error('dsh-mole: SKILL.md has no frontmatter')
  const field = (key) => {
    const line = new RegExp(`^${key}: (".*")$`, 'mu').exec(match[1])
    if (line === null) throw new Error(`dsh-mole: SKILL.md has no ${key}`)
    return JSON.parse(line[1])
  }
  return {
    // The host's catalog shows the model only name and description, so the
    // non-English trigger phrases have to live in the description here.
    description: `${field('description')} Triggers: ${field('when_to_use')}`,
    content: text.slice(match[0].length).trim(),
  }
}

async function loadSkill() {
  return parseSkill(await readFile(SKILL_FILE, 'utf8'))
}

const provider = {
  name: PROVIDER,
  async list() {
    const { description } = await loadSkill()
    return [{
      name: 'mole',
      description,
      invocation: INVOCATION,
      provider: PROVIDER,
      source: 'bundled',
      resourceBase: RESOURCE_BASE,
      rank: RANK,
      locator: SKILL_FILE,
    }]
  },
  async get() {
    const { description, content } = await loadSkill()
    return {
      name: 'mole',
      description,
      invocation: INVOCATION,
      provider: PROVIDER,
      source: 'bundled',
      resourceBase: RESOURCE_BASE,
      content,
    }
  },
}

export const name = 'dsh-mole'
export const inject = ['skills']

export function apply(ctx) {
  ctx.skills.registerProvider(() => provider)
}
