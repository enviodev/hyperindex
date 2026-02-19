type arg = string

type parsedArgs<'a> = 'a

@module("yargs/yargs") external yargs: array<arg> => parsedArgs<'a> = "default"
@module("yargs/helpers") external hideBin: array<arg> => array<arg> = "hideBin"

@get external argv: parsedArgs<'a> => 'a = "argv"
