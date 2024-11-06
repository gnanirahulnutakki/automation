import argparse
import logging
import os
import sys
import yaml
from jinja2 import Environment, FileSystemLoader, TemplateNotFound

def setup_logging():
    """Set up logging configuration."""
    logging.basicConfig(level=logging.INFO, format='%(levelname)s: %(message)s')

def parse_args():
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(description='Generate Fluent Bit configuration.')
    parser.add_argument('values_file', help='Path to the values.yaml file')
    parser.add_argument('-o', '--output', help='Path to save the generated configuration file', default='fluent-bit.conf')
    return parser.parse_args()

def validate_values(values):
    """Validate the required keys in the values dictionary."""
    if 'metrics' not in values or 'fluentbit' not in values['metrics']:
        raise ValueError("The values.yaml file must contain 'metrics.fluentbit' section.")
    if 'logs' not in values['metrics']['fluentbit']:
        raise ValueError("The 'metrics.fluentbit' section must contain 'logs'.")

def load_values(values_file):
    """Load and parse the YAML values file."""
    try:
        with open(values_file, 'r') as f:
            values = yaml.safe_load(f)
            return values
    except FileNotFoundError:
        logging.error(f"The file {values_file} does not exist.")
        sys.exit(1)
    except yaml.YAMLError as exc:
        logging.error(f"Error parsing YAML file: {exc}")
        sys.exit(1)

def generate_config(values):
    """Generate the Fluent Bit configuration using templates."""
    env = Environment(loader=FileSystemLoader('.'), trim_blocks=True, lstrip_blocks=True)
    try:
        service_template = env.get_template('templates/service.conf.j2')
        input_template = env.get_template('templates/input.conf.j2')
        filter_template = env.get_template('templates/filter.conf.j2')
        output_template = env.get_template('templates/output.conf.j2')
        parsers_template = env.get_template('templates/parsers.conf.j2')
    except TemplateNotFound as exc:
        logging.error(f"Template not found: {exc}")
        sys.exit(1)

    fluentbit_config = values['metrics']['fluentbit']
    logs = fluentbit_config.get('logs', {})
    aggregators = fluentbit_config.get('aggregators', [])
    cluster_name = values.get('zk', {}).get('clusterName', 'fid-cluster')

    config_sections = []

    # Generate [SERVICE] section
    service_config = service_template.render()
    config_sections.append(service_config)

    # Generate [INPUT] sections
    indexes = {}
    for log_name, log_config in logs.items():
        if log_config.get('enabled', False):
            input_config = input_template.render(log_name=log_name, log_config=log_config)
            config_sections.append(input_config)
            indexes[log_name] = log_config.get('custom_index', log_config.get('index', log_name))

    # Generate [FILTER] section
    filter_config = filter_template.render(cluster_name=cluster_name)
    config_sections.append(filter_config)

    # Generate [OUTPUT] sections
    output_configs = []
    for aggregator in aggregators:
        for log_name, index_name in indexes.items():
            output_config = output_template.render(aggregator=aggregator, log_name=log_name, index_name=index_name)
            output_configs.append(output_config)
    config_sections.extend(output_configs)

    # Generate parsers.conf if any logs have parsing configuration
    parsers_configs = []
    for log_name, log_config in logs.items():
        if log_config.get('enabled', False) and 'parse' in log_config:
            parser_config = parsers_template.render(log_name=log_name, parse_config=log_config['parse'])
            parsers_configs.append(parser_config)
    parsers_content = '\n'.join(parsers_configs)

    return '\n'.join(config_sections), parsers_content

def main():
    """Main function."""
    setup_logging()
    args = parse_args()
    values = load_values(args.values_file)
    try:
        validate_values(values)
    except ValueError as exc:
        logging.error(exc)
        sys.exit(1)

    fluentbit_conf, parsers_conf = generate_config(values)

    # Write the generated configurations to files
    output_dir = os.path.dirname(args.output)
    if output_dir and not os.path.exists(output_dir):
        os.makedirs(output_dir)

    with open(args.output, 'w') as f:
        f.write(fluentbit_conf)
        logging.info(f"Fluent Bit configuration written to {args.output}")

    parsers_output = os.path.join(output_dir, 'parsers.conf')
    with open(parsers_output, 'w') as f:
        f.write(parsers_conf)
        logging.info(f"Parsers configuration written to {parsers_output}")

if __name__ == "__main__":
    main()
