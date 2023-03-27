type defer = {resolve: (. unit) => unit}

@module("jest-bench") external benchmarkSuite: (string, {..}) => unit = "benchmarkSuite"
