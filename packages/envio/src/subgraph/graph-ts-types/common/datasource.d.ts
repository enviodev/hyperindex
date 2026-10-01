import './eager-offset';
import { Entity } from './collections';
import { Address } from './numbers';
/** Host interface for managing data sources */
export declare namespace dataSource {
    function create(name: string, params: Array<string>): void;
    function createWithContext(name: string, params: Array<string>, context: DataSourceContext): void;
    function address(): Address;
    function network(): string;
    function context(): DataSourceContext;
}
export declare namespace dataSource {
    function stringParam(): string;
}
/** Context for dynamic data sources */
export declare class DataSourceContext extends Entity {
}
/**
 * Base class for data source templates. Allows to dynamically create
 * data sources from templates at runtime.
 */
export declare class DataSourceTemplate {
    /**
     * Dynamically creates a data source from the template with the
     * given name, using the parameter strings to configure the new
     * data source.
     */
    static create(name: string, params: Array<string>): void;
    static createWithContext(name: string, params: Array<string>, context: DataSourceContext): void;
}
