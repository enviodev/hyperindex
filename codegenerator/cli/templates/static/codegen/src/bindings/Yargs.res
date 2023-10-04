type arg = string

type parsedArgs<'a> = 'a

@module external yargs: array<arg> => parsedArgs<'a> = "yargs/yargs"
@module("yargs/helpers") external hideBin: array<arg> => array<arg> = "hideBin"

@get external argv: parsedArgs<'a> => 'a = "argv"
