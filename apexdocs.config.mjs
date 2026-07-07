import { defineMarkdownConfig } from '@cparra/apexdocs';

export default defineMarkdownConfig({
  sourceDir: 'force-app',
  targetDir: 'docs/apex',
  scope: ['public', 'global', 'private', 'isTest'],
  defaultGroupName: 'Miscellaneous',
  sortAlphabetically: true,
  referenceGuideTitle: 'AAO Apex Reference Guide'
});
