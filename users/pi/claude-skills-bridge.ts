/**
 * claude-skills-bridge
 *
 * Loads Claude Code skills into pi:
 * - ~/.claude/skills: global user skills, always loaded
 * - <cwd>/.claude/skills: project skills, loaded for trusted projects
 */

import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
    pi.on("resources_discover", async (event, ctx) => {
        const skillPaths: string[] = [];

        const globalSkillsPath = join(homedir(), ".claude", "skills");
        if (existsSync(globalSkillsPath)) {
            skillPaths.push(globalSkillsPath);
        }

        if (ctx.isProjectTrusted()) {
            const projectSkillsPath = join(event.cwd, ".claude", "skills");
            if (existsSync(projectSkillsPath)) {
                skillPaths.push(projectSkillsPath);
            }
        }

        if (skillPaths.length > 0) return { skillPaths };
    });
}
