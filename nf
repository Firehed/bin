#!/usr/bin/env php
<?php

function usage() {
    $msg = <<<'FOO'
Usage: %s [-tis] ClassName

    Options:
    -t, --trait: Generate a Trait
    -i, --interface: Generate an Interface
    -s, --strict: Add `declare(strict_types=1);`
    -h, --help: Show help and exit

If the class name ends in `Test`, it will be assumed to be a PHPUnit test case
and will automatically extends `\PHPUnit\Framework\TestCase`.

FOO;
    e($msg, $_SERVER['argv'][0]);

}
if ($argc < 2) {
    usage();
}

// find composer manifest
$search = getcwd();
while (1) {
	$try = $search.DIRECTORY_SEPARATOR."composer.json";
	if (file_exists($try)) {
		$manifest = file_get_contents($try);
		define('PROJECT_ROOT', $search.DIRECTORY_SEPARATOR);
		break;
	}
	if ($search == DIRECTORY_SEPARATOR) {
		e("composer.json could not be found");
	}
	$search = dirname($search);
}

$data = json_decode($manifest, true);
if (JSON_ERROR_NONE !== json_last_error()) {
	e("Reading composer.json failed");
}
if (!isset($data['autoload']) && !isset($data['autoload-dev'])) {
	e("No autoloader configured in composer.json");
}

$parseLoader = function($autoload) {
    $ns = null;
    if (isset($autoload['psr-4'])) {
        $ns = handlePSR4($autoload['psr-4']);
    }
    elseif (isset($autoload['psr-0'])) {
        handlePSR0($autload['psr-0']);
    }
    else {
        e("No PSR-4 or PSR-0 autoload configured");
    }
    return $ns;
};

foreach (['autoload', 'autoload-dev'] as $index) {
    $ns = $parseLoader($data[$index] ?? []);
    if ($ns) break;
}


if (!$ns) {
	e("Current path does not appear to be a defined namespace");
}

$opts = getopt('tish', ['trait', 'interface', 'strict', 'help']);
if (isset($opts['h']) || isset($opts['help'])) {
    usage();
}
$classname = end($argv);
$is_test = 'Test' == substr($classname, -4);
$is_interface = isset($opts['i']) || isset($opts['interface']);
$is_trait = isset($opts['t']) || isset($opts['test']);
$is_strict = isset($opts['s']) || isset($opts['strict']);

if ($is_trait) $type = 'trait';
elseif ($is_interface) $type = 'interface';
else $type = 'class';

buildfile($ns, end($argv), $is_test, $type, $is_strict);

function buildfile($ns, $classname, $is_test, $type, $strict) {
	if (!is_writable(getcwd())) {
		e("Current directory is not writable");
	}
	$filename = sprintf('%s.php', $classname);
	if (file_exists($filename)) {
		e("File %s already exists!", $filename);
	}
    $strict_types = $strict ? "\ndeclare(strict_types=1);\n" : '';
	$template = <<<GENPHP
<?php
%s
namespace %s;
%s
%s %s%s
{

}
GENPHP;
	$docblock = '';
	$extends = '';
	if ($is_test) {
		$extends = ' extends \PHPUnit\Framework\TestCase';
		$covered_class = substr($classname, 0, -4); // trim trailing Test
		$docblock = <<<GENPHP

/**
 * @covers $ns\\$covered_class
 */
GENPHP;
	}
	$contents = sprintf($template, $strict_types, $ns, $docblock, $type, $classname, $extends);
	file_put_contents($filename, $contents);
	echo "Wrote generated file to $filename\n";
	exit(0);
}

function handlePSR4(array $configs) {
	$cwd = getcwd().DIRECTORY_SEPARATOR; // Necessary for root-level dir in NS
	foreach ($configs as $prefix => $pathspecs) {
        $prefix = rtrim($prefix, '\\');
		foreach ((array)$pathspecs as $pathspec) {
			if (!$pathspec) continue; // Ignore empty, it's valid but dumb
			$try = PROJECT_ROOT.$pathspec;
			if (0 === strpos($cwd, $try)) {
				$sub = strtr(substr($cwd, strlen($try)), '/', '\\');
				$ns = rtrim($prefix.$sub, '\\'); // trim trailing NS sep
				return $ns;
			}
		}
	}
	return null;
}

function handlePSR0(array $configs) {
	var_dump($configs);
}

function e($msg, ...$args) {
	fwrite(STDERR, sprintf($msg, ...$args)."\n");
	exit(1);
}
