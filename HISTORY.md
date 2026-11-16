# History

The current project was written from scratch in November 2026. The layout is
a single playbook with roles and one config file, and all task code,
templates and helper scripts are new. The repository history starts at that
rewrite.

Earlier public versions of this repository (before November 2026) were
adapted from
[IEquilibriumI/dune-selfhost-ansible](https://github.com/IEquilibriumI/dune-selfhost-ansible),
which is licensed GPL-3.0. Those versions remain under GPL-3.0. None of their
code is part of the current project.

The rewrite still interoperates with Funcom's payload. It therefore uses the
same facts every Linux self-host setup needs: the script paths, image and
resource names, operator flags, Steam app ID, ports, and the order of
`world.sh`'s prompts. These come from Funcom's server package.
