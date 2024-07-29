type config = {path: string}
type envRes

@module("dotenv") external config: config => envRes = "config"
