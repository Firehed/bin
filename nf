#!/usr/bin/env php
<?php

declare(strict_types=1);

enum TemplateType
{
    case AutoDetect;
    case PlainClass; // class is a reserved name
    case Enum;
    case Trait;
    case Interface;
    case TestCase;
}

class Project
{
    /**
     * Absolute path to project root, as defined by presence of composer.json
     */
    public readonly string $root;

    public function __construct(public readonly string $cwd)
    {
        $this->root = $this->findProjectRoot($cwd);
    }

    private function findProjectRoot(string $cwd): string
    {
        do {
            $composerJson = $cwd . '/composer.json';
            if (file_exists($composerJson)) {
                return $cwd;
            }
            // Go one higher
            $cwd = dirname($cwd);
        } while ($cwd !== DIRECTORY_SEPARATOR);

        throw new \RuntimeException('composer.json not found all the way up to FS root');
    }

    public function readComposerJson(): array
    {
        return $this->read('composer.json');
    }

    public function readComposerLock(): array
    {
        return $this->read('composer.lock');
    }

    private function read(string $file): array
    {
        $path = $this->root . '/' . $file;
        $json = file_get_contents($path);
        return json_decode($json, true, flags: JSON_THROW_ON_ERROR);
    }
}

class NamespaceLocator
{
    /**
     * Path from project root (without leading or trailing DS)
     */
    private string $relativeCwd;

    private array $relativeDirectoryToNamespace;

    public function __construct(private Project $project)
    {
        $this->relativeCwd = $this->findRelativeCwd($project->cwd);

        $this->processComposerJson();
    }

    private function findRelativeCwd(string $cwd): string
    {
        return self::normalizePath(mb_substr($cwd, mb_strlen($this->project->root)));
    }

    private function processComposerJson(): void
    {
        $data = $this->project->readComposerJson();

        $psr4Parser = function ($data) {
            foreach ($data as $namespace => $directories) {
                foreach ((array) $directories as $directory) {
                    $this->relativeDirectoryToNamespace[self::normalizePath($directory)] = self::normalizePath($namespace);
                }
            }
        };

        $autoload = $data['autoload']['psr-4'] ?? [];
        $autoloadDev = $data['autoload-dev']['psr-4'] ?? [];
        $psr4Parser($autoload);
        $psr4Parser($autoloadDev);

        // FIXME: warn on PSR-0 presence or otherwise no mappings
    }

    /**
     * @return array{
     *   fqcn: string,
     *   file: string,
     * }
     */
    public function resolve(string $arg): array
    {
        // FIXME: resolve ../ stuff
        $target = $this->relativeCwd . '/' . self::normalizePath($arg);
        foreach ($this->relativeDirectoryToNamespace as $dir => $baseNs) {
            if (str_starts_with(haystack: $target, needle: $dir)) {
                // We've found a NS root - replace the relative root dir with the NS
                $relativeNs = mb_substr($target, mb_strlen($dir));
                $fqcn = self::pathToNs($baseNs . $relativeNs);
                return [
                    'fqcn' => $fqcn,
                    'file' => sprintf('%s/%s.php', $this->project->root, $target),
                ];
            }
        }
        throw new RuntimeException('Could not resolve namespace - are your autoloaders set right?');
    }

    /**
     * Takes a given path and normalizes it by:
     * - Turning any backslashes to slashes
     * - Removing leading or trailing whitespace
     * - Removing leading or trailing slashes
     */
    private static function normalizePath(string $path): string
    {
        $trimmed = trim($path);
        $slashes = str_replace('\\', '/', $trimmed);
        return trim($slashes, '/');
    }

    private static function pathToNs(string $path): string
    {
        return str_replace('/', '\\', $path);
    }
}

class TemplateBuilder
{
    private TemplateType $type = TemplateType::AutoDetect;
    private bool $strictMode = true; // do not make configurable?

    private string $namespace;
    private string $name;

    // Metadata
    private array $uses = [];
    private array $annotations = [];
    private array $attributes = [];
    private ?string $extends = null;


    public function __construct(private Project $project, string $fqcn)
    {
        $components = explode('\\', $fqcn);

        $this->name = array_pop($components);
        $this->namespace = implode('\\', $components);
    }

    /**
     * The type can explicitly be set and will override autodetection
     */
    public function setType(TemplateType $type)
    {
        $this->type = $type;
    }

    private function getTypeName(): string
    {
        return match ($this->type) {
            TemplateType::PlainClass => 'class',
            TemplateType::Enum => 'enum',
            TemplateType::Interface => 'interface',
            TemplateType::Trait => 'trait',
            TemplateType::TestCase => 'class',
            // AutoDetect intentionally excluded
        };
    }

    private function detectType(): TemplateType
    {
        assert($this->type === TemplateType::AutoDetect);
        // TODO: assert name is set ?
        if (str_ends_with($this->name, 'Enum')) {
            return TemplateType::Enum;
        } elseif (str_ends_with($this->name, 'Interface')) {
            return TemplateType::Interface;
        } elseif (str_ends_with($this->name, 'Trait')) {
            return TemplateType::Trait;
        } elseif (str_ends_with($this->name, 'Test')) {
            return TemplateType::TestCase;
        }
        return TemplateType::PlainClass;
    }

    public function write(string $to): void
    {
        file_put_contents($to, $this->build());
    }

    private function build(): string
    {
        // FIXME: move this check?
        if ($this->type === TemplateType::AutoDetect) {
            $this->type = $this->detectType();
        }

        if ($this->type === TemplateType::TestCase) {
            $this->setExtends(\PHPUnit\Framework\TestCase::class);
            $classBeingTested = substr($this->name, 0, -4); // name without Test

            if ($this->shouldUsePHPUnitAttributes()) {
                $this->attributes[] = "#[CoversClass({$classBeingTested}::class)]";
                $this->uses[] = \PHPUnit\Framework\Attributes\CoversClass::class;
            } else {
                $this->annotations[] = "@covers {$classBeingTested}";
            }
        }

        $tpl = <<<php
        <?php

        {$this->buildStrict()}

        namespace {$this->namespace};

        {$this->buildUses()}

        {$this->buildAnnotationsAndAttributes()}
        {$this->getTypeName()} {$this->name} {$this->buildExtends()}
        {
        }
        php;

        // Collapse consecutive blank lines
        $outputWithoutDupeNewline = preg_replace('/\n\n\n+/', "\n\n", $tpl);
        // Now trim trailing whitespace (note: not \s which grabs newlines too)
        return preg_replace('/\h+$/m', '', $outputWithoutDupeNewline);
    }

    private function buildStrict(): string
    {
        return $this->strictMode ? 'declare(strict_types=1);' : '';
    }

    private function buildUses(): string
    {
        if (!$this->uses) {
            return '';
        }

        $uses = array_map(fn ($fqcn) => "use $fqcn;", $this->uses);
        sort($uses);

        return "\n" . implode("\n", $uses) . "\n";
    }

    private function buildAnnotationsAndAttributes(): string
    {
        $annotations = $this->buildAnnotations();
        $attributes = $this->buildAttributes();

        if (!$annotations) {
            return $attributes;
        }
        if (!$attributes) {
            return $annotations;
        }
        // Both are set. Combine.
        return sprintf("%s\n%s", $annotations, $attributes);
    }

    private function buildAnnotations(): string
    {
        if (!$this->annotations) {
            return '';
        }
        $formattedAnnotations = array_map(fn ($plain) => ' * ' . $plain, $this->annotations);
        return sprintf("/**\n%s\n */", implode("\n", $formattedAnnotations));
    }

    private function buildAttributes(): string
    {
        if (!$this->attributes) {
            return '';
        }
        sort($this->attributes);
        return implode("\n", $this->attributes);
    }

    private function buildExtends(): string
    {
        if ($this->extends) {
            return sprintf('extends %s', $this->extends);
        }
        return '';
    }

    private function setExtends(string $base): void
    {
        $this->uses[] = $base;
        $parts = explode('\\', $base);
        $this->extends = end($parts);
    }

    private function shouldUsePHPUnitAttributes(): bool
    {
        $lockData = $this->project->readComposerLock();

        $findPhpunit = function ($packageList): ?array {
            foreach ($packageList as $package) {
                if ($package['name'] === 'phpunit/phpunit') {
                    return $package;
                }
            }
            return null;
        };

        if ($requireDev = $findPhpunit($lockData['packages-dev'])) {
            return version_compare($requireDev['version'], '10.0.0', '>=');
        } elseif ($require = $findPhpunit($lockData['packages'])) {
            return version_compare($require['version'], '10.0.0', '>=');
        }

        trigger_error(E_USER_WARNING, 'PHPUnit not found, acting as 10+');
        return true;
    }
}

function e($msg, ...$args): never
{
	fwrite(STDERR, sprintf($msg, ...$args)."\n");
	exit(1);
}


function usage(): never
{
    $msg = <<<'FOO'
Usage: %s [-tis] ClassName

    Options:
    -t, --trait: Generate a Trait
    -i, --interface: Generate an Interface
    -e, --enum: Generate an Enum
    -h, --help: Show help and exit

If the class name ends in `Test`, it will be assumed to be a PHPUnit test case
and will automatically extends `\PHPUnit\Framework\TestCase`.

FOO;
    e($msg, $_SERVER['argv'][0]);

}

// SCRIPT STARTS HERE

if ($argc < 2) {
    usage();
}

// Read option flags
$opts = getopt('tieh', ['trait', 'interface', 'enum', 'help']);
if (isset($opts['h']) || isset($opts['help'])) {
    usage();
}
$name = end($argv);

$project = new Project(getcwd());
$nsl = new NamespaceLocator($project);
$info = $nsl->resolve($name);

$builder = new TemplateBuilder($project, $info['fqcn']);

if (isset($opts['i']) || isset($opts['interface'])) {
    $builder->setType(TemplateType::Interface);
} elseif (isset($opts['t']) || isset($opts['trait'])) {
    $builder->setType(TemplateType::Trait);
} elseif (isset($opts['e']) || isset($opts['enum'])) {
    $builder->setType(TemplateType::Enum);
}

$builder->write(to: $info['file']);

echo "Generated file {$info['file']}\n";
