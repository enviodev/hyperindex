import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    projects: [
      {
        extends: true,
        test: {
          name: "templates",
          include: ["src/template-tests/**/*.test.ts"],
          pool: "threads",
          poolOptions: {
            threads: {
              singleThread: false,
            },
          },
          testTimeout: 120000,
        },
      },
      {
        extends: true,
        test: {
          name: "e2e",
          include: ["src/e2e/**/*.test.ts"],
          pool: "forks",
          poolOptions: {
            forks: {
              singleFork: true,
            },
          },
          testTimeout: 300000,
        },
      },
    ],
  },
});
